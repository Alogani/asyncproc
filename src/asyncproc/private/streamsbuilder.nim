import std/deques
import asyncio, asyncio/[asyncpipe, asyncstream, asynchainreader, asynctee, asynciodelayed]

import ../exports/procargs

type
    StreamsBuilder* = ref object
        flags*: set[BuilderFlags]
        stdin, stdout, stderr: AsyncIoBase
        closeWhenWaited: seq[AsyncIoBase]
        transferWaiters: seq[Future[void]]
        closeWhenCapturesFlushed: seq[AsyncIoBase]

    BuilderFlags* = enum
        InteractiveStdin, InteractiveOut,
        CaptureStdin, CaptureStdout, CaptureStderr
        MergeStderr

let delayedStdoutAsync = AsyncIoDelayed.new(stdoutAsync, 1)
let delayedStderrAsync = AsyncIoDelayed.new(stderrAsync, 2)

proc init*(T: type StreamsBuilder; stdin, stdout, stderr: AsyncioBase; keepStreamOpen, mergeStderr: bool): StreamsBuilder
proc addStreamToStdinChain*(builder: StreamsBuilder, newStream: AsyncIoBase)
proc addStreamtoStdout*(builder: StreamsBuilder, newStream: AsyncIoBase)
proc addStreamtoStderr*(builder: StreamsBuilder, newStream: AsyncIoBase)
proc addStreamtoOutImpl(stream: var AsyncIoBase, newStream: AsyncIoBase)
# Builders must be called in that order
proc buildStdinInteractive(builder: StreamsBuilder)
proc buildOutInteractive(builder: StreamsBuilder)
proc buildOutInteractiveImpl(stream: var AsyncIoBase, stdStream, stdStreamDelayed: AsyncIoBase)
proc buildStdinCapture(builder: StreamsBuilder): Future[string]
proc buildStdoutCapture(builder: StreamsBuilder): Future[string]
proc buildStderrCapture(builder: StreamsBuilder): Future[string]
proc buildOutCaptureImpl(builder: StreamsBuilder, stream: var AsyncIoBase): Future[string]
proc buildToStreams*(builder: StreamsBuilder): tuple[
    streams: tuple[stdin, stdout, stderr: AsyncIoBase],
    captures: tuple[input, output, outputErr: Future[string]],
    transferWaiters: seq[Future[void]],
    closeWhenWaited, closeWhenCapturesFlushed: seq[AsyncIoBase]]
proc buildToChildFile*(builder: StreamsBuilder, closeEvent: Future[void]): tuple[
    stdFiles: tuple[stdin, stdout, stderr: Asyncfile],
    captures: tuple[input, output, outputErr: Future[string]],
    transferWaiters: seq[Future[void]],
    closeWhenWaited, closeWhenCapturesFlushed: seq[AsyncIoBase]]
proc buildOutChildFileImpl(builder: StreamsBuilder, stream: AsyncIoBase): AsyncFile
proc buildImpl(builder: StreamsBuilder): tuple[captures: tuple[input, output, outputErr: Future[string]]]
proc toPassFds*(stdin, stdout, stderr: AsyncFile): seq[tuple[src: FileHandle, dest: FileHandle]]
proc nonStandardStdin*(builder: StreamsBuilder): bool


proc init*(T: type StreamsBuilder; stdin, stdout, stderr: AsyncioBase; keepStreamOpen, mergeStderr: bool): StreamsBuilder =
    result = StreamsBuilder(
        flags: (if mergeStderr: { BuilderFlags.MergeStderr } else: {}),
        stdin: stdin,
        stdout: stdout,
        stderr: stderr,
    )
    if not keepStreamOpen:
        if stdin != nil:
            result.closeWhenWaited.add stdin
        if stdout != nil:
            result.closeWhenWaited.add stdout
        if stderr != nil:
            result.closeWhenWaited.add stderr

proc addStreamToStdinChain*(builder: StreamsBuilder, newStream: AsyncIoBase) =
    if builder.stdin == nil:
        builder.stdin = newStream
    elif builder.stdin == newStream:
        discard
    elif builder.stdin of AsyncChainReader:
        AsyncChainReader(builder.stdin).addReader newStream
    else:
        builder.stdin = AsyncChainReader.new(builder.stdin, newStream)

proc addStreamtoStdout*(builder: StreamsBuilder, newStream: AsyncIoBase) =
    builder.stdout.addStreamtoOutImpl(newStream)

proc addStreamtoStderr*(builder: StreamsBuilder, newStream: AsyncIoBase) =
    builder.stderr.addStreamtoOutImpl(newStream)

proc buildStdinInteractive(builder: StreamsBuilder) =
    builder.addStreamToStdinChain(stdinAsync)

proc addStreamtoOutImpl(stream: var AsyncIoBase, newStream: AsyncIoBase) =
    if stream == nil:
        stream = newStream
    elif stream == newStream:
        discard
    elif stream of AsyncTeeWriter:
        AsyncTeeWriter(stream).writers.add(newStream)
    else:
        stream = AsyncTeeWriter.new(stream, newStream)

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
    builder.closeWhenWaited.add captureIo.writer
    return captureIo.readAll()

proc buildStdoutCapture(builder: StreamsBuilder): Future[string] =
    builder.buildOutCaptureImpl(builder.stdout)

proc buildStderrCapture(builder: StreamsBuilder): Future[string] =
    builder.buildOutCaptureImpl(builder.stderr)

proc buildOutCaptureImpl(builder: StreamsBuilder, stream: var AsyncIoBase): Future[string] =
    if stream != nil:
        let captureIo = AsyncStream.new()
        if stream of AsyncTeeWriter:
            AsyncTeeWriter(stream).writers.add(captureIo)
        else:
            stream = AsyncTeeWriter.new(stream, captureIo.writer)
        builder.closeWhenWaited.add captureIo.writer
        builder.closeWhenCapturesFlushed.add captureIo.reader
        return captureIo.reader.readAll()
    else:
        var pipe = AsyncPipe.new()
        stream = pipe.writer
        builder.closeWhenWaited.add pipe.writer
        builder.closeWhenCapturesFlushed.add pipe.reader
        return pipe.reader.readAll()

proc buildToStreams*(builder: StreamsBuilder): tuple[
    streams: tuple[stdin, stdout, stderr: AsyncIoBase],
    captures: tuple[input, output, outputErr: Future[string]],
    transferWaiters: seq[Future[void]],
    closeWhenWaited, closeWhenCapturesFlushed: seq[AsyncIoBase]
] =
    ## Closing is handled internally, so output should not be closed using anything else as toClose return value
    let (captures) = builder.buildImpl()
    return (
        (builder.stdin, builder.stdout, builder.stderr),
        captures,
        builder.transferWaiters,
        builder.closeWhenWaited,
        builder.closeWhenCapturesFlushed
    )

proc buildToChildFile*(builder: StreamsBuilder, closeEvent: Future[void]): tuple[
    stdFiles: tuple[stdin, stdout, stderr: Asyncfile],
    captures: tuple[input, output, outputErr: Future[string]],
    transferWaiters: seq[Future[void]],
    closeWhenWaited, closeWhenCapturesFlushed: seq[AsyncIoBase]
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
            builder.transferWaiters.add builder.stdin.transfer(pipe.writer, closeEvent).then(proc() {.async.} =
                pipe.writer.close()
            )
            builder.closeWhenWaited.add pipe.reader
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
        builder.transferWaiters,
        builder.closeWhenWaited,
        builder.closeWhenCapturesFlushed
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
        builder.transferWaiters.add pipe.reader.transfer(stream).then(proc() {.async.} = pipe.reader.close())
        builder.closeWhenWaited.add pipe.writer
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

proc nonStandardStdin*(builder: StreamsBuilder): bool =
    ## if stdin is open and will not be equal to stdinAsync -> check before any build occurs
    (InteractiveStdin in builder.flags or builder.stdin == stdinAsync) and CaptureStdin in builder.flags