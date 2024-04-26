import std/deques
import asyncio, asyncio/[asyncpipe, asyncstream, asynchainreader, asynctee, asynciodelayed]

import ../exports/procargs

type
    StreamsBuilder* = ref object
        flags*: set[BuilderFlags]
        stdin, stdout, stderr: AsyncIoBase
        toClose: seq[AsyncIoBase]
        toCloseWhenFlushed: seq[AsyncIoBase]

    BuilderFlags* = enum
        InteractiveStdin, InteractiveOut,
        CaptureStdin, CaptureStdout, CaptureStderr
        MergeStderr

let delayedStdoutAsync = AsyncIoDelayed.new(stdoutAsync, 1)
let delayedStderrAsync = AsyncIoDelayed.new(stderrAsync, 2)

proc init*(T: type StreamsBuilder; stdin, stdout, stderr: AsyncioBase; mergeStderr: bool): StreamsBuilder
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
    toClose: seq[AsyncIoBase], toCloseWhenFlushed: seq[AsyncIoBase]]
proc buildToChildFile*(builder: StreamsBuilder, closeEvent: Future[void]): tuple[
    stdFiles: tuple[stdin, stdout, stderr: Asyncfile],
    captures: tuple[input, output, outputErr: Future[string]],
    toClose: seq[AsyncIoBase], toCloseWhenFlushed: seq[AsyncIoBase]]
proc buildOutChildFileImpl(builder: StreamsBuilder, stream: AsyncIoBase): AsyncFile
proc buildImpl(builder: StreamsBuilder): tuple[captures: tuple[input, output, outputErr: Future[string]]]
proc toPassFds*(stdin, stdout, stderr: AsyncFile): seq[tuple[src: FileHandle, dest: FileHandle]]
proc isInteractiveButNoInherit*(builder: StreamsBuilder): bool


proc init*(T: type StreamsBuilder; stdin, stdout, stderr: AsyncioBase; mergeStderr: bool): StreamsBuilder =
    result = StreamsBuilder(
        flags: (if mergeStderr: { BuilderFlags.MergeStderr } else: {}),
        stdin: stdin,
        stdout: stdout,
        stderr: stderr,
    )
    if stdin != nil:
        result.toClose.add stdin
    if stdout != nil:
        result.toCloseWhenFlushed.add stdout
    if stderr != nil:
        result.toCloseWhenFlushed.add stderr

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
    builder.toCloseWhenFlushed.add captureIo
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
        builder.toCloseWhenFlushed.add captureIo
        return captureIo
    else:
        var pipe = AsyncPipe.new()
        stream = pipe.writer
        builder.toClose.add pipe.writer
        builder.toCloseWhenFlushed.add pipe.reader
        return pipe.reader

proc buildToStreams*(builder: StreamsBuilder): tuple[
    streams: tuple[stdin, stdout, stderr: AsyncIoBase],
    captures: tuple[input, output, outputErr: Future[string]],
    toClose: seq[AsyncIoBase], toCloseWhenFlushed: seq[AsyncIoBase]
] =
    let (captures) = builder.buildImpl()
    return (
        (builder.stdin, builder.stdout, builder.stderr),
        captures,
        builder.toClose,
        builder.toCloseWhenFlushed,
    )

proc buildToChildFile*(builder: StreamsBuilder, closeEvent: Future[void]): tuple[
    stdFiles: tuple[stdin, stdout, stderr: Asyncfile],
    captures: tuple[input, output, outputErr: Future[string]],
    toClose: seq[AsyncIoBase], toCloseWhenFlushed: seq[AsyncIoBase]
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
            builder.toClose.add pipe.writer
            builder.toClose.add pipe.reader
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
        builder.toClose,
        builder.toCloseWhenFlushed,
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
        discard pipe.reader.transfer(stream)
        builder.toCloseWhenFlushed.add pipe.reader
        builder.toClose.add pipe.writer
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

proc toPassFds*(stdin, stdout, stderr: AsyncFile): seq[tuple[src: FileHandle, dest: FileHandle]] =
    if stdin != nil:
        result.add (stdin.fd, 0.FileHandle)
    if stdout != nil:
        result.add (stdout.fd, 1.FileHandle)
    if stderr != nil:
        result.add (stderr.fd, 2.FileHandle)

proc isInteractiveButNoInherit*(builder: StreamsBuilder): bool =
    InteractiveStdin in builder.flags and (builder.stdin != nil or builder.stdin != stdinAsync)