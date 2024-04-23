import std/[options, strutils, deques]
import asyncio, asyncio/[asyncpipe, asyncstream, asynchainreader, asynctee, asynciodelayed]

import ./procargs {.all.}
import ./procenv {.all.}
import ./procresult {.all.}

when defined(windows):
    raise newException(LibraryError)
else:
    import ../private/childproc_posix


type
    AsyncProc* = ref object #{.requiresInit.} = ref object
        # To many ways to provide input/output streams, so no public stdin/stdout accessible
        childProc: ChildProc
        cmd: seq[string]
        logFn: LogFn
        onErrorFn: OnErrorFn
        captureStreams: tuple[input, output, outputErr: Future[string]]
        isBeingWaited: Listener
        outputTransferFinished: Future[void]
        waitFinished: Event
        cleanups: proc()

#[
Used when both Interactive is set and MergeStderr is not set, otherwise:
    - stdout can appear before stdin has issued a newline
    - prompt (stderr) can appear before command output
]#
let delayedStdoutAsync = AsyncIoDelayed.new(stderrAsync, 1)
let delayedStderrAsync = AsyncIoDelayed.new(stderrAsync, 2)

proc askYesNo(sh: ProcArgs, text: string): bool

proc start*(sh: ProcArgs, cmd: seq[string], argsModifier = ProcArgsModifier()): AsyncProc =
    ## It is the responsability of the caller to close its end of AsyncStream, AsyncPipe, etc. to avoid deadlocks
    ## Some commands will only work well if stdin is connected to a pseudo terminal: if parent is inside a terminal, then don't use CaptureInput, and use either Interactive with stdin = nil or stdin = stdinAsync
    if cmd.len() == 0:
        raise newException(ExecError, "Can't run an empty command")
    var
        args = sh.merge(argsModifier)
        (stdinBuilder, stdoutBuilder, stderrBuilder) =
            (args.input.stream, args.output.stream, args.outputErr.stream)
        cmdBuilt = args.buildCommand(cmd)
        processName = (if args.processName == "": cmdBuilt[0] else: args.processName)
        closeAfterSpawn: seq[AsyncFile]
        closeAfterOutTransfer: seq[AsyncIoBase]
        closeAfterWaited: seq[AsyncIoBase]
        outputTransferFinishedList: seq[Future[void]]
        waitFinished = Event.new()
        env = (
            if SetEnvOnCmdLine in args.options:
                newEmptyEnv()
            elif UseParentEnv in args.options:
                newParentEnv().mergeEnv(args.env)
            else:
                args.env
            )
    block closeWhenOver:
        if args.input.closeWhenOver:
            if args.input.stream of AsyncFile:
                closeAfterSpawn.add AsyncFile(args.input.stream)
            elif args.input.stream of AsyncPipe:
                closeAfterSpawn.add AsyncPipe(args.input.stream).reader
                closeAfterWaited.add AsyncPipe(args.input.stream).writer
            else:
                closeAfterWaited.add args.input.stream
        for (stream, closeWhenOver)in @[(args.output.stream, args.output.closeWhenOver), (args.outputErr.stream, args.outputErr.closeWhenOver)]:
            if closeWhenOver:
                if stream of AsyncFile:
                    closeAfterSpawn.add AsyncFile(stream)
                elif args.input.stream of AsyncPipe:
                    closeAfterSpawn.add AsyncPipe(stream).writer
                    closeAfterWaited.add AsyncPipe(stream).reader
                else:
                    closeAfterWaited.add stream
    if AskConfirmation in args.options:
        if not sh.askYesNo("You are about to run following command:\n" &
                            ">>> " & $cmdBuilt & "\nDo you confirm ?"):
            return AsyncProc(childProc: ChildProc(), cmd: cmdBuilt)
    elif ShowCommand in args.options:
        echo ">>> ", cmdBuilt
    if DryRun in args.options:
        return AsyncProc(childProc: ChildProc(), cmd: cmdBuilt)
    #[ Parent stream incluse logic ]#
    if Interactive in args.options:
        block stdin:
            if stdinBuilder == nil or stdinBuilder == stdinAsync:
                stdinBuilder = stdinAsync
            elif stdinBuilder of AsyncChainReader:
                AsyncChainReader(stdinBuilder).readers.addLast stdinAsync
            else:
                stdinBuilder = AsyncChainReader.new(stdinBuilder, stdinAsync)
        proc updateOutBuilder(builder: var AsyncIoBase, stdStream, stdStreamDelayed: AsyncIoBase) =
            if builder == nil:
                builder = stdStreamDelayed
            elif builder == stdStream:
                discard
            elif builder of AsyncTeeWriter:
                AsyncTeeWriter(builder).writers.add(stdStreamDelayed)
            else:
                builder = AsyncTeeWriter.new(builder, stdStreamDelayed)
        if MergeStderr in args.options:
            stdoutBuilder.updateOutBuilder(stdoutAsync, delayedStdoutAsync)
            stderrBuilder.updateOutBuilder(stderrAsync, delayedStderrAsync)
        else:
            stdoutBuilder.updateOutBuilder(stdoutAsync, stdoutAsync)
            stderrBuilder = nil
    #[ Capture logic ]#
    # if capture is a asyncpipe, must not be read lazy to avoid child IO deadlock
    # if capture is a asyncstream, no point to make it lazy (already takes memory)
    var stdinCapture, stdoutCapture, stderrCapture: Future[string]
    block captures:
        block stdin:
            if CaptureInput in args.options and stdinBuilder != nil:
                let captureIo = AsyncStream.new()
                stdinBuilder = AsyncTeeReader.new(stdinBuilder, captureIo)
                closeAfterOutTransfer.add captureIo
                stdinCapture = captureIo.readAll()
        proc getOutCapture(builder: var AsyncIoBase): Future[string] {.closure.} =
            if builder != nil:
                let captureIo = AsyncStream.new()
                if builder of AsyncTeeWriter:
                    AsyncTeeWriter(builder).writers.add(captureIo)
                else:
                    builder = AsyncTeeWriter.new(builder, captureIo)
                closeAfterOutTransfer.add captureIo
                return captureIo.readAll()
            else:
                var pipe = AsyncPipe.new()
                builder = pipe.writer
                closeAfterSpawn.add pipe.writer
                closeAfterWaited.add pipe.reader
                return pipe.reader.readAll()
        if CaptureOutput in args.options:
            stdoutCapture = getOutCapture(stdoutBuilder)
        if CaptureOutputErr in args.options and MergeStderr notin args.options:
            stderrCapture = getOutCapture(stderrBuilder)
    #[ Set up child's stdin, stdout and stderr ]#
    var stdinChild, stdoutChild, stderrChild: AsyncFile
    var useFakePty: bool
    if Interactive in args.options and stdinBuilder != nil and stdinBuilder != stdinAsync:
        ## Mandatory to create a fake terminal
        useFakePty = true
        var streams = newChildTerminal(MergeStderr in args.options)
        stdinChild = streams.stdinChild
        stdoutChild = streams.stdoutChild
        stderrChild = streams.stderrChild
        var
            stdinWriter = streams.stdinWriter
            stdoutReader = streams.stdoutReader
            stderrReader = streams.stderrReader
        closeAfterSpawn.add @[stdinChild, stdoutChild, stderrChild]
        closeAfterWaited.add @[stdoutReader]
        discard stdinBuilder.transfer(stdinWriter, waitFinished)
        outputTransferFinishedList.add stdoutReader.transfer(stdoutBuilder)
        if stderrReader != nil:
            outputTransferFinishedList.add stderrReader.transfer(stderrBuilder)
    else:
        stdinChild = (
            if stdinBuilder == nil:
                nil
            elif stdinBuilder of AsyncPipe:
                AsyncPipe(stdinBuilder).reader
            elif stdinBuilder of AsyncFile:
                AsyncFile(stdinBuilder)
            else:
                var pipe = AsyncPipe.new()
                discard stdinBuilder.transfer(pipe.writer, waitFinished)
                closeAfterSpawn.add pipe.reader
                closeAfterWaited.add pipe.writer
                pipe.reader
        )
        proc initOutChild(child: var AsyncFile, builder: AsyncIoBase) {.closure.} =
            if builder == nil:
                child = nil
            elif builder of AsyncFile:
                child = AsyncFile(builder)
            elif builder of AsyncPipe:
                child = AsyncPipe(builder).writer
            else:
                var pipe = AsyncPipe.new()
                outputTransferFinishedList.add pipe.reader.transfer(builder)
                closeAfterSpawn.add pipe.writer
                closeAfterWaited.add pipe.reader
                child = pipe.writer
        stdoutChild.initOutChild(stdoutBuilder)
        if MergeStderr in args.options:
            stderrChild = stdoutChild
        else:
            stderrChild.initOutChild(stderrBuilder)
    var passFds = newSeq[tuple[src: FileHandle, dest: FileHandle]]()
    if stdinChild != nil: passFds.add (FileHandle(stdinChild.fd), Filehandle(0))
    if stdoutChild != nil: passFds.add (FileHandle(stdoutChild.fd), FileHandle(1))
    if stderrChild != nil: passFds.add (FileHandle(stderrChild.fd), FileHandle(2))
    let childProc = startProcess(cmdBuilt[0], @[processName] & cmdBuilt[1..^1],
        passFds, env, args.workingDir, Daemon in args.options, fakePty = useFakePty)
    var outputTransferFinished = all(outputTransferFinishedList)
    result = AsyncProc(
        childProc: childProc,
        cmd: cmdBuilt,
        logFn: if WithLogging in args.options: args.logFn else: nil,
        onErrorFn: args.onErrorFn,
        captureStreams: (stdinCapture, stdoutCapture, stderrCapture),
        isBeingWaited: Listener.new(),
        outputTransferFinished: outputTransferFinished,
        waitFinished: waitFinished,
        cleanups: proc() {.closure.} =
            if useFakePty:
                restoreTerminal()
            for stream in closeAfterWaited:
                stream.close()
    )
    for fileStream in closeAfterSpawn:
        fileStream.close()
    outputTransferFinished.addCallback(proc () =
        for stream in closeAfterOutTransfer:
            stream.close()
    )

proc wait*(self: AsyncProc, cancelFut: Future[void] = nil): Future[ProcResult] {.async.} =
    ## Raise error if cancelFut is triggered
    if not self.childProc.hasExited:
        if not self.isBeingWaited.isListening():
            addProcess(self.childProc.getPid(), proc(_: AsyncFd): bool {.gcsafe.} =
                self.isBeingWaited.trigger()
                return true
            )
        await any(self.isBeingWaited.wait(), cancelFut)
        if not self.isBeingWaited.isTriggered():
            raise newException(OsError, "Timeout expired")
    let exitCode = self.childProc.wait()
    await self.outputTransferFinished
    result = ProcResult(
        cmd: self.cmd,
        input:
            (if self.captureStreams.input != nil:
               await self.captureStreams.input
            else:
                ""),
        output:
            (if self.captureStreams.output != nil:
                await self.captureStreams.output
            else:
                ""),
        outputErr:
            (if self.captureStreams.outputErr != nil:
                await self.captureStreams.outputErr
            else:
                ""),
        exitCode: exitCode,
        success: exitCode == 0,
    )
    self.waitFinished.trigger()
    self.cleanups()
    result.setOnErrorFn(self.onErrorFn)
    if self.logFn != nil:
        self.logFn(result)

proc getPid*(p: AsyncProc): int = p.childProc.getPid()
proc running*(p: AsyncProc): bool = p.childProc.running()
proc suspend*(p: AsyncProc) = p.childProc.suspend()
proc resume*(p: AsyncProc) = p.childProc.resume()
## wait() should be called after terminate to clean up resource
proc terminate*(p: AsyncProc) = p.childProc.terminate()
## wait() should be called after kill to clean up resource
proc kill*(p: AsyncProc) = p.childProc.kill()


proc run*(sh: ProcArgs, cmd: seq[string], argsModifier = ProcArgsModifier(),
cancelFut: Future[void] = nil): Future[ProcResult] {.async.} =
    await sh.start(cmd, argsModifier).wait(cancelFut)

proc runAssert*(sh: ProcArgs, cmd: seq[string], argsModifier = ProcArgsModifier(),
cancelFut: Future[void] = nil): Future[ProcResult] {.async.} =
    assertSuccess await sh.start(cmd, argsModifier).wait(cancelFut)

proc runAssertDiscard*(sh: ProcArgs, cmd: seq[string], argsModifier = ProcArgsModifier(),
cancelFut: Future[void] = nil): Future[void] {.async.} =
    when defined(release):
        discard assertSuccess await sh.start(cmd,
            argsModifier.merge(toRemove = { CaptureInput, CaptureOutput, CaptureOutputErr })
        ).wait(cancelFut)
    else:
        # Easier debugging
        discard assertSuccess await sh.start(cmd,
            argsModifier.merge(toRemove = { CaptureInput, CaptureOutput })
        ).wait(cancelFut)

proc runCheck*(sh: ProcArgs, cmd: seq[string], argsModifier = ProcArgsModifier(),
cancelFut: Future[void] = nil): Future[bool] {.async.} =
    await(sh.start(cmd,
        argsModifier.merge(toRemove = (when defined(release):
            { MergeStderr, CaptureInput, CaptureOutputErr }
        else:
            { MergeStderr, CaptureInput }
        ))
    ).wait(cancelFut)).success

proc runGetOutput*(sh: ProcArgs, cmd: seq[string], argsModifier = ProcArgsModifier(),
cancelFut: Future[void] = nil): Future[string] {.async.} =
    ## LineEnd is always stripped, because it is usually unawanted. Use sh.run if this comportement is not wanted
    ## Ignore MergeStderrOption
    withoutLineEnd (assertSuccess await(sh.start(cmd,
        argsModifier.merge(
            toAdd = { CaptureOutput },
            toRemove = (when defined(release):
                { MergeStderr, CaptureInput, CaptureOutputErr }
            else:
                { MergeStderr, CaptureInput }
            )
    )).wait(cancelFut))).output

proc runGetLines*(sh: ProcArgs, cmd: seq[string], argsModifier = ProcArgsModifier(),
cancelFut: Future[void] = nil): Future[seq[string]] {.async.} =
    splitLines withoutLineEnd await sh.runGetOutput(cmd, argsModifier)

proc runGetOutputStream*(sh: ProcArgs, cmd: seq[string], argsModifier = ProcArgsModifier(),
cancelFut: Future[void] = nil): (AsyncIoBase, Future[void]) =
    ## Return also the future to indicate end of subprocess
    ## Ignore MergeStderrOption
    var pipe = AsyncPipe.new()
    var finishFut = sh.runAssertDiscard(cmd,
        argsModifier.merge(
            toRemove = (when defined(release):
                    { MergeStderr, Interactive, CaptureOutput, CaptureInput, CaptureOutputErr }
                else:
                    { MergeStderr, Interactive, CaptureOutput, CaptureInput }
                ),
            output = some (pipe.AsyncIoBase, true)
    ), cancelFut)
    return (pipe.reader, finishFut)

proc runGetStreams*(sh: ProcArgs, cmd: seq[string], argsModifier = ProcArgsModifier(),
cancelFut: Future[void] = nil): (AsyncIoBase, AsyncIoBase, Future[void]) =
    ## Return also the future to indicate end of subprocess
    ## Ignore MergeStderr option
    var outputPipe = AsyncPipe.new()
    var outputErrPipe = AsyncPipe.new()
    var finishFut = sh.runAssertDiscard(cmd,
        argsModifier.merge(
            toRemove = (when defined(release):
                    { MergeStderr, Interactive, CaptureOutput, CaptureInput, CaptureOutputErr }
                else:
                    { MergeStderr, Interactive, CaptureOutput, CaptureInput }
                ),
            output = some (outputPipe.AsyncIoBase, true),
            outputErr = some (outputErrPipe.AsyncIoBase, true)
    ), cancelFut)
    return (outputPipe.reader, outputErrPipe.reader, finishFut)


proc askYesNo(sh: ProcArgs, text: string): bool =
    # A more complte version is available in myshellcmd/ui
    while true:
        stdout.write(text)
        stdout.write " [sh/y/n]? "
        let response = readLine(stdin).normalize()
        if response in ["y", "yes"]:
            return true
        if response in ["n", "no"]:
            return false
        if response in ["sh", "shell", "bash"]:
            discard waitFor sh.run(@["bash", "--norc", "-i"], ProcArgsModifier(
                toAdd: { Interactive },
                envModifier: some {"PS1": "bash$ "}.toTable()
            ))
            stdout.write("\n")
        else:
            echo "Response is not in available choice. Please try again.\n"