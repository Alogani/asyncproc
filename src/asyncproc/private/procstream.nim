import std/deques
import asyncio, asyncio/[asyncpipe, asyncstream, asynchainreader, asynctee, asynciodelayed]

import ../exports/procargs

type
    StreamsBuilder* = ref object
        stdin*, stdout*, stderr*: AsyncIoBase
        mergeStderr*: bool
        ownedStreams*: seq[AsyncIoBase] 
        transferWaiters*: seq[Future[void]]

let delayedStdoutAsync = AsyncIoDelayed.new(stdoutAsync, 1)
let delayedStderrAsync = AsyncIoDelayed.new(stderrAsync, 2)

proc init*(T: type StreamsBuilder, stdin, stdout, stderr: StreamArg, mergeStderr: bool): StreamsBuilder
proc makeInteractive*(builder: StreamsBuilder)
proc makeOutStreamInteractive(stream: var AsyncIoBase, stdStream, stdStreamDelayed: AsyncIoBase)
proc captureStdin*(builder: StreamsBuilder): Future[string]
proc captureStdout*(builder: StreamsBuilder): Future[string]
proc captureStderr*(builder: StreamsBuilder): Future[string]
proc captureOutStream(builder: StreamsBuilder, stream: var AsyncIoBase): AsyncIoBase
proc closeAllOwnedStreams*(builder: StreamsBuilder)
proc waitForAllTransfers*(builder: StreamsBuilder): Future[void]
# Implementation specific utils:
proc toChildFile(builder: StreamsBuilder, childWaited: Event): tuple[stdin, stdout, stderr: AsyncFile] {.used.}
proc toChildOutStreamFile(builder: StreamsBuilder, stream: AsyncIoBase): AsyncFile
proc closeIfOwned(builder: StreamsBuilder, file: AsyncFile) {.used.}
proc toPassFds(stdin, stdout, stderr: AsyncFile): seq[tuple[src: FileHandle, dest: FileHandle]] {.used.}


proc init*(T: type StreamsBuilder, stdin, stdout, stderr: StreamArg, mergeStderr: bool): StreamsBuilder =
    result = StreamsBuilder(
        stdin: stdin.stream,
        stdout: stdout.stream,
        stderr: stderr.stream,
        mergeStderr: mergeStderr
    )
    if stdin.closeWhenOver:
        result.ownedStreams.add stdin.stream
    if stdout.closeWhenOver:
        result.ownedStreams.add stdout.stream
    if stderr.closeWhenOver:
        result.ownedStreams.add stderr.stream

proc makeInteractive*(builder: StreamsBuilder) =
    if builder.stdin == nil:
        builder.stdin = stdinAsync
    elif builder.stdin == stdinAsync:
        discard
    elif builder.stdin of AsyncChainReader:
        AsyncChainReader(builder.stdin).readers.addLast stdinAsync
    else:
        builder.stdin = AsyncChainReader.new(builder.stdin, stdinAsync)

    if builder.mergeStderr:
        builder.stdout.makeOutStreamInteractive(stdoutAsync, delayedStdoutAsync)
        builder.stderr.makeOutStreamInteractive(stderrAsync, delayedStderrAsync)
    else:
        builder.stdout.makeOutStreamInteractive(stdoutAsync, stdoutAsync)
        builder.stderr = nil

proc makeOutStreamInteractive(stream: var AsyncIoBase, stdStream, stdStreamDelayed: AsyncIoBase) =
    if stream == nil:
        stream = stdStreamDelayed
    elif stream == stdStream:
        discard
    elif stream of AsyncTeeWriter:
        AsyncTeeWriter(stream).writers.add(stdStreamDelayed)
    else:
        stream = AsyncTeeWriter.new(stream, stdStreamDelayed)

proc captureStdin*(builder: StreamsBuilder): Future[string] =
    if builder.stdin == nil:
        return
    let captureIo = AsyncStream.new()
    builder.stdin = AsyncTeeReader.new(builder.stdin, captureIo)
    builder.ownedStreams.add captureIo
    return captureIo.readAll()

proc captureStdout*(builder: StreamsBuilder): Future[string] =
    builder.captureOutStream(builder.stdout).readAll()

proc captureStderr*(builder: StreamsBuilder): Future[string] =
    builder.captureOutStream(builder.stderr).readAll()

proc captureOutStream(builder: StreamsBuilder, stream: var AsyncIoBase): AsyncIoBase =
    if stream != nil:
        let captureIo = AsyncStream.new()
        if stream of AsyncTeeWriter:
            AsyncTeeWriter(stream).writers.add(captureIo)
        else:
            stream = AsyncTeeWriter.new(stream, captureIo)
        builder.ownedStreams.add captureIo
        return captureIo
    else:
        var pipe = AsyncPipe.new()
        stream = pipe.writer
        builder.ownedStreams.add pipe
        return pipe.reader

proc closeAllOwnedStreams*(builder: StreamsBuilder) =
    for stream in builder.ownedStreams:
        stream.close()
    builder.ownedStreams.setLen(0)

proc waitForAllTransfers*(builder: StreamsBuilder): Future[void] =
    all(builder.transferWaiters)


proc toChildFile(builder: StreamsBuilder, childWaited: Event): tuple[stdin, stdout, stderr: AsyncFile] =
    if builder.stdin == nil:
        result.stdin = nil
    elif builder.stdin of AsyncPipe:
        result.stdin = AsyncPipe(builder.stdin).reader
    elif builder.stdin of AsyncFile:
        result.stdin = AsyncFile(builder.stdin)
    else:
        var pipe = AsyncPipe.new()
        discard builder.stdin.transfer(pipe.writer, childWaited)
        builder.ownedStreams.add pipe
        result.stdin = pipe.reader

    result.stdout = builder.toChildOutStreamFile(builder.stdout)
    if builder.mergeStderr:
        result.stderr = result.stdout
    else:
        result.stderr = builder.toChildOutStreamFile(builder.stderr)

proc toChildOutStreamFile(builder: StreamsBuilder, stream: AsyncIoBase): AsyncFile =
    if stream == nil:
        return nil
    elif stream of AsyncFile:
        return AsyncFile(stream)
    elif stream of AsyncPipe:
        return AsyncPipe(stream).writer
    else:
        var pipe = AsyncPipe.new()
        builder.transferWaiters.add pipe.reader.transfer(stream)
        builder.ownedStreams.add pipe
        return pipe.writer

proc closeIfOwned(builder: StreamsBuilder, file: AsyncFile) =
    if file == nil:
        return
    var ownedStreams: seq[AsyncIoBase]
    for stream in builder.ownedStreams:
        if stream == file:
            stream.close()
            continue
        elif stream of AsyncPipe:
            let pipe = AsyncPipe(stream)
            if pipe.reader == file:
                pipe.reader.close()
                continue
            elif pipe.writer == file:
                pipe.writer.close()
                continue
        ownedStreams.add stream
    builder.ownedStreams = ownedStreams


proc toPassFds(stdin, stdout, stderr: AsyncFile): seq[tuple[src: FileHandle, dest: FileHandle]] =
    if stdin != nil:
        result.add (stdin.fd, 0.FileHandle)
    if stdout != nil:
        result.add (stdout.fd, 1.FileHandle)
    if stderr != nil:
        result.add (stderr.fd, 2.FileHandle)