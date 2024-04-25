import std/deques
import asyncio, asyncio/[asyncpipe, asyncstream, asynchainreader, asynctee, asynciodelayed]

import ../exports/procargs

type
    StreamsBuilder* = ref object
        flags*: set[BuilderFlags]
        stdin, stdout, stderr: AsyncIoBase
        ownedStreams: seq[AsyncIoBase]
        transferWaiters: seq[Future[void]]

    BuilderFlags* = enum
        InteractiveStdin, InteractiveOut,
        CaptureStdin, CaptureStdout, CaptureStderr
        MergeStderr

let delayedStdoutAsync = AsyncIoDelayed.new(stdoutAsync, 1)
let delayedStderrAsync = AsyncIoDelayed.new(stderrAsync, 2)

proc init*(T: type StreamsBuilder, stdin, stdout, stderr: StreamArg, mergeStderr: bool): StreamsBuilder
# Builders must be called in that order
proc buildStdinInteractive(builder: StreamsBuilder)
proc buildOutInteractive(builder: StreamsBuilder)
proc buildOutInteractiveImpl(stream: var AsyncIoBase, stdStream, stdStreamDelayed: AsyncIoBase)
proc buildStdinCapture(builder: StreamsBuilder): Future[string]
proc buildStdoutCapture(builder: StreamsBuilder): Future[string]
proc buildStderrCapture(builder: StreamsBuilder): Future[string]
proc buildOutCaptureImpl(builder: StreamsBuilder, stream: var AsyncIoBase): AsyncIoBase
proc buildToStreams*(builder: StreamsBuilder): tuple[
    streams: tuple[stdin, stdout, stderr: AsyncIoBase],
    captures: tuple[input, output, outputErr: Future[string]],
    ownedStreams: seq[AsyncIoBase], transferWaiters: seq[Future[void]]]
proc buildToChildFile*(builder: StreamsBuilder, closeEvent: Future[void]): tuple[
    stdFiles: tuple[stdin, stdout, stderr: Asyncfile],
    captures: tuple[input, output, outputErr: Future[string]],
    ownedStreams: seq[AsyncIoBase], transferWaiters: seq[Future[void]]]
proc buildOutChildFileImpl(builder: StreamsBuilder, stream: AsyncIoBase): AsyncFile
proc buildImpl(builder: StreamsBuilder): tuple[captures: tuple[input, output, outputErr: Future[string]]]
proc toPassFds*(stdin, stdout, stderr: AsyncFile): seq[tuple[src: FileHandle, dest: FileHandle]]
proc closeIfFound*(ownedStreams: var seq[AsyncIoBase], file: AsyncFile)
proc isInteractiveButNoInherit*(builder: StreamsBuilder): bool


proc init*(T: type StreamsBuilder, stdin, stdout, stderr: StreamArg, mergeStderr: bool): StreamsBuilder =
    result = StreamsBuilder(
        flags: (if mergeStderr: { BuilderFlags.MergeStderr } else: {}),
        stdin: stdin.stream,
        stdout: stdout.stream,
        stderr: stderr.stream,
    )
    if stdin.closeWhenOver:
        result.ownedStreams.add stdin.stream
    if stdout.closeWhenOver:
        result.ownedStreams.add stdout.stream
    if stderr.closeWhenOver:
        result.ownedStreams.add stderr.stream

proc buildStdinInteractive(builder: StreamsBuilder) =
    if builder.stdin == nil:
        builder.stdin = stdinAsync
    elif builder.stdin == stdinAsync:
        discard
    elif builder.stdin of AsyncChainReader:
        AsyncChainReader(builder.stdin).readers.addLast stdinAsync
    else:
        builder.stdin = AsyncChainReader.new(builder.stdin, stdinAsync)

proc buildOutInteractive(builder: StreamsBuilder) =
    if MergeStderr in builder.flags:
        builder.stdout.buildOutInteractiveImpl(stdoutAsync, stdoutAsync)
        builder.stderr = builder.stdout
    else:
        builder.stdout.buildOutInteractiveImpl(stdoutAsync, delayedStdoutAsync)
        builder.stderr.buildOutInteractiveImpl(stderrAsync, delayedStderrAsync)

proc buildOutInteractiveImpl(stream: var AsyncIoBase, stdStream, stdStreamDelayed: AsyncIoBase) =
    if stream == nil:
        stream = stdStreamDelayed
    elif stream == stdStream:
        discard
    elif stream of AsyncTeeWriter:
        AsyncTeeWriter(stream).writers.add(stdStreamDelayed)
    else:
        stream = AsyncTeeWriter.new(stream, stdStreamDelayed)

proc buildStdinCapture(builder: StreamsBuilder): Future[string] =
    if builder.stdin == nil:
        return
    let captureIo = AsyncStream.new()
    builder.stdin = AsyncTeeReader.new(builder.stdin, captureIo)
    builder.ownedStreams.add captureIo
    return captureIo.readAll()

proc buildStdoutCapture(builder: StreamsBuilder): Future[string] =
    builder.buildOutCaptureImpl(builder.stdout).readAll()

proc buildStderrCapture(builder: StreamsBuilder): Future[string] =
    builder.buildOutCaptureImpl(builder.stderr).readAll()

proc buildOutCaptureImpl(builder: StreamsBuilder, stream: var AsyncIoBase): AsyncIoBase =
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

proc buildToStreams*(builder: StreamsBuilder): tuple[
    streams: tuple[stdin, stdout, stderr: AsyncIoBase],
    captures: tuple[input, output, outputErr: Future[string]],
    ownedStreams: seq[AsyncIoBase], transferWaiters: seq[Future[void]]
] =
    let (captures) = builder.buildImpl()
    return (
        (builder.stdin, builder.stdout, builder.stderr),
        captures,
        builder.ownedStreams,
        builder.transferWaiters
    )

proc buildToChildFile*(builder: StreamsBuilder, closeEvent: Future[void]): tuple[
    stdFiles: tuple[stdin, stdout, stderr: Asyncfile],
    captures: tuple[input, output, outputErr: Future[string]],
    ownedStreams: seq[AsyncIoBase], transferWaiters: seq[Future[void]]
] =
    let (captures) = builder.buildImpl()
    let stdin =
        if builder.stdin == nil:
            nil
        elif builder.stdin of AsyncPipe:
            AsyncPipe(builder.stdin).reader
        elif builder.stdin of AsyncFile:
            AsyncFile(builder.stdin)
        else:
            var pipe = AsyncPipe.new()
            discard builder.stdin.transfer(pipe.writer, closeEvent)
            builder.ownedStreams.add pipe
            pipe.reader
    let stdout = builder.buildOutChildFileImpl(builder.stdout)
    let stderr =
        if MergeStderr in builder.flags:
            stdout
        else:
            builder.buildOutChildFileImpl(builder.stderr)
    return (
        (stdin, stdout, stderr),
        captures,
        builder.ownedStreams,
        builder.transferWaiters
    )

proc buildOutChildFileImpl(builder: StreamsBuilder, stream: AsyncIoBase): AsyncFile =
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

proc buildImpl(builder: StreamsBuilder): tuple[captures: tuple[input, output, outputErr: Future[string]]] =
    if InteractiveStdin in builder.flags:
        builder.buildStdinInteractive()
    if InteractiveOut in builder.flags:
        builder.buildOutInteractive()
    if CaptureStdin in builder.flags:
        result.captures.input = builder.buildStdinCapture()
    if CaptureStdout in builder.flags:
        result.captures.output = builder.buildStdoutCapture()
    if CaptureStderr in builder.flags:
        result.captures.outputErr = builder.buildStderrCapture()

proc closeIfFound*(ownedStreams: var seq[AsyncIoBase], file: AsyncFile) =
    if file == nil:
        return
    var ownedStreams2: seq[AsyncIoBase]
    for stream in ownedStreams:
        if stream == file:
            stream.close()
            continue
        elif stream of AsyncPipe:
            let pipe = AsyncPipe(stream)
            if pipe.reader == file:
                pipe.reader.close()
                ownedStreams2.add pipe.writer
                continue
            elif pipe.writer == file:
                pipe.writer.close()
                ownedStreams2.add pipe.reader
                continue
        ownedStreams2.add stream
    ownedStreams = ownedStreams2

proc toPassFds*(stdin, stdout, stderr: AsyncFile): seq[tuple[src: FileHandle, dest: FileHandle]] =
    if stdin != nil:
        result.add (stdin.fd, 0.FileHandle)
    if stdout != nil:
        result.add (stdout.fd, 1.FileHandle)
    if stderr != nil:
        result.add (stderr.fd, 2.FileHandle)

proc isInteractiveButNoInherit*(builder: StreamsBuilder): bool =
    InteractiveStdin in builder.flags and (builder.stdin == nil or builder.stdin == stdinAsync)