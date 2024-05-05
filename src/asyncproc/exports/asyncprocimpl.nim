import std/[options, strutils]
import asyncio
import asyncsync, asyncsync/osevents

import ./procargsresult {.all.}
import ./procenv {.all.}
import ../private/streamsbuilder

when defined(windows):
    raise newException(LibraryError)
else:
    import ../private/childproc_posix


type
    AsyncProc* = ref object
        ## It corresponds to the running process. It can be obtained with startProcess.
        ## It must also be waited with wait() to cleanup its resource (opened files, memory, etc.).
        ## It provides basic process manipulation, like kill/suspend/terminate/running/getPid.
        ## Because this module provides complex IO handling, its standard streams are not accessible and should not be direclty used.
        ## To manipulate its IO, use input/output/outputErr (be creative with AsyncIo library) and flags from ProcArgs.
        childProc: ChildProc
        fullCmd: seq[string] # for debugging purpose
        cmd: seq[string]  # for debugging purpose
        procArgs: ProcArgs # for debugging purpose
        captureStreams: tuple[input, output, outputErr: Future[string]]
        closeWhenCapturesFlushed: seq[AsyncIoBase]
        hasExitedEvent: ProcessEvent
        afterWaitCleanup: proc(): Future[void]
    
var RunningProcesses*: seq[AsyncProc]
## RunningProcesses list process that have been spawned with Register flag and have not been waited.
## Process are listed in order of spawn
## Process are not guaranted to exist if `wait` has not been called

proc askYesNo(sh: ProcArgs, text: string): bool


proc start*(sh: ProcArgs, cmd: seq[string], argsModifier: ProcArgsModifier): AsyncProc =
    ## It is the responsability of the caller to close its end of AsyncStream, AsyncPipe, etc. to avoid deadlocks
    ## Some commands will only work well if stdin is connected to a pseudo terminal: if parent is inside a terminal, then don't use CaptureInput, and use either Interactive with stdin = nil or stdin = stdinAsync
    if cmd.len() == 0:
        raise newException(ExecError, "Can't run an empty command")
    var
        args = sh.merge(argsModifier)
        cmdBuilt = args.buildCommand(cmd)
        processName = (if args.processName == "": cmdBuilt[0] else: args.processName)
        env = (
            if SetEnvOnCmdLine in args.options:
                # Already included on cmdline
                newEmptyEnv()
            elif NoParentEnv in args.options:
                args.env
            else:
                newEnvFromParent().mergeEnv(args.env)
            )
    if AskConfirmation in args.options:
        if not sh.askYesNo("You are about to run following command:\n" &
                            ">>> " & $cmdBuilt & "\nDo you confirm ?"):
            return AsyncProc(childProc: ChildProc(), fullCmd: cmdBuilt, procArgs: args)
    elif ShowCommand in args.options:
        echo ">>> ", cmdBuilt
    if DryRun in args.options:
        return AsyncProc(childProc: ChildProc(), fullCmd: cmdBuilt, procArgs: args)
    
    #[ Parent stream incluse logic ]#
    var streamsBuilder = StreamsBuilder.init(args.input, args.output, args.outputErr,
                            KeepStreamOpen in args.options, MergeStderr in args.options)
    if Interactive in args.options:
        streamsBuilder.flags.incl { InteractiveStdin, InteractiveOut }
    if CaptureInput in args.options:
        streamsBuilder.flags.incl CaptureStdin
    if CaptureOutput in args.options:
        streamsBuilder.flags.incl CaptureStdout
    if CaptureOutputErr in args.options and MergeStderr notin args.options:
        streamsBuilder.flags.incl CaptureStderr
    let (passFds, captures, useFakePty, closeWhenCapturesFlushed, afterSpawn, afterWait) =
        streamsBuilder.toChildStream()
    let childProc = startProcess(cmdBuilt[0], @[processName] & cmdBuilt[1..^1],
        passFds, env, args.workingDir,
        Daemon in args.options, fakePty = useFakePty, IgnoreInterrupt in args.options)
    afterSpawn()
    result = AsyncProc(
        childProc: childProc,
        fullCmd: cmdBuilt,
        cmd: cmd,
        procArgs: args,
        captureStreams: captures,
        closeWhenCapturesFlushed: closeWhenCapturesFlushed,
        afterWaitCleanup: afterWait,
    )
    if RegisterProcess in args.options:
        RunningProcesses.add result

proc start*(sh: ProcArgs, cmd: seq[string], prefixCmd = none(seq[string]), toAdd: set[ProcOption] = {}, toRemove: set[ProcOption] = {},
        input = none(AsyncIoBase), output = none(AsyncIoBase), outputErr = none(AsyncIoBase),
        env = none(ProcEnv), envModifier = none(ProcEnv), workingDir = none(string),
        processName = none(string), logFn = none(LogFn), onErrorFn = none(OnErrorFn)): AsyncProc =
    start(sh, cmd, ProcArgsModifier(prefixCmd: prefixCmd, toAdd: toAdd, toRemove: toRemove,
        input: input, output: output, outputErr: outputErr,
        env: env, envModifier: envModifier, workingDir: workingDir,
        processName: processName, logFn: logFn, onErrorFn: onErrorFn))

proc wait*(self: AsyncProc, cancelFut: Future[void] = nil): Future[ProcResult] {.async.} =
    ## Permits to wait for the subprocess to finish in a async way
    ## Mandatory to clean up its resource (opened files, memory, etc.) (apart if the process is intended to be a daemon)
    ## Will not close or kill the subprocess, so it can be a deadlock if subprocess is waiting for input (solution is to close it)
    ## However this function doesn't need to be called to flush process output (automatically done to avoid pipie size limit deadlock)
    ## Raise OsError if cancelFut is triggered
    if not self.childProc.hasExited:
        if self.hasExitedEvent == nil:
            self.hasExitedEvent = ProcessEvent.new(self.childProc.getPid())
        if not await self.hasExitedEvent.getFuture().wait(cancelFut):
            raise newException(OsError, "Timeout expired")
    let exitCode = self.childProc.wait()
    if RegisterProcess in self.procArgs.options:
        RunningProcesses.delete(RunningProcesses.find(self))
    await self.afterWaitCleanup()
    result = ProcResult(
        fullCmd: self.fullCmd,
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
        procArgs: self.procArgs,
    )
    result.setOnErrorFn(self.procArgs.onErrorFn) # Private field
    for stream in self.closeWhenCapturesFlushed:
        stream.close()
    if self.procArgs.logFn != nil:
        self.procArgs.logFn(result)

proc getPid*(p: AsyncProc): int = p.childProc.getPid()
proc running*(p: AsyncProc): bool = p.childProc.running()
proc suspend*(p: AsyncProc) = p.childProc.suspend()
proc resume*(p: AsyncProc) = p.childProc.resume()
proc terminate*(p: AsyncProc) = p.childProc.terminate()
    ## wait() should be called after terminate to clean up resource
proc kill*(p: AsyncProc) = p.childProc.kill()
    ## wait() should be called after kill to clean up resource

proc pretty*(self: AsyncProc): string =
    return "## AsyncProcess: " & $self.fullCmd &
        "\n- Pid: " & $self.getPid() &
        "\n- Running: " & $self.running() &
        "\n- Options: " & $self.procArgs.options

proc run*(sh: ProcArgs, cmd: seq[string], argsModifier: ProcArgsModifier,
cancelFut: Future[void] = nil): Future[ProcResult] {.async.} =
    ## A sugar to combine `sh.start(...).wait()` in a single call
    await sh.start(cmd, argsModifier).wait(cancelFut)

proc run*(sh: ProcArgs, cmd: seq[string], prefixCmd = none(seq[string]), toAdd: set[ProcOption] = {}, toRemove: set[ProcOption] = {},
        input = none(AsyncIoBase), output = none(AsyncIoBase), outputErr = none(AsyncIoBase),
        env = none(ProcEnv), envModifier = none(ProcEnv), workingDir = none(string),
        processName = none(string), logFn = none(LogFn), onErrorFn = none(OnErrorFn), cancelFut: Future[void] = nil): Future[ProcResult] =
    run(sh, cmd, ProcArgsModifier(prefixCmd: prefixCmd, toAdd: toAdd, toRemove: toRemove,
        input: input, output: output, outputErr: outputErr,
        env: env, envModifier: envModifier, workingDir: workingDir,
        processName: processName, logFn: logFn, onErrorFn: onErrorFn), cancelFut)

proc runAssert*(sh: ProcArgs, cmd: seq[string], argsModifier: ProcArgsModifier,
cancelFut: Future[void] = nil): Future[ProcResult] {.async.} =
    ## A sugar to combine `sh.start(...).wait(...).assertSuccess()` in a single call
    await sh.start(cmd, argsModifier).wait(cancelFut).assertSuccess()

proc runAssert*(sh: ProcArgs, cmd: seq[string], prefixCmd = none(seq[string]), toAdd: set[ProcOption] = {}, toRemove: set[ProcOption] = {},
        input = none(AsyncIoBase), output = none(AsyncIoBase), outputErr = none(AsyncIoBase),
        env = none(ProcEnv), envModifier = none(ProcEnv), workingDir = none(string),
        processName = none(string), logFn = none(LogFn), onErrorFn = none(OnErrorFn), cancelFut: Future[void] = nil): Future[ProcResult] =
    runAssert(sh, cmd, ProcArgsModifier(prefixCmd: prefixCmd, toAdd: toAdd, toRemove: toRemove,
        input: input, output: output, outputErr: outputErr,
        env: env, envModifier: envModifier, workingDir: workingDir,
        processName: processName, logFn: logFn, onErrorFn: onErrorFn), cancelFut)

proc runDiscard*(sh: ProcArgs, cmd: seq[string], argsModifier: ProcArgsModifier,
cancelFut: Future[void] = nil): Future[void] {.async.} =
    ## A sugar to combine `discard sh.start(...).wait(...).assertSuccess()` in a single call
    when defined(release):
        discard await sh.start(cmd,
            argsModifier.merge(toRemove = { CaptureInput, CaptureOutput, CaptureOutputErr })
        ).wait(cancelFut).assertSuccess()
    else:
        # Easier debugging
        discard await sh.start(cmd,
            argsModifier.merge(toRemove = { CaptureInput, CaptureOutput })
        ).wait(cancelFut).assertSuccess()

proc runDiscard*(sh: ProcArgs, cmd: seq[string], prefixCmd = none(seq[string]), toAdd: set[ProcOption] = {}, toRemove: set[ProcOption] = {},
        input = none(AsyncIoBase), output = none(AsyncIoBase), outputErr = none(AsyncIoBase),
        env = none(ProcEnv), envModifier = none(ProcEnv), workingDir = none(string),
        processName = none(string), logFn = none(LogFn), onErrorFn = none(OnErrorFn), cancelFut: Future[void] = nil): Future[void] =
    runDiscard(sh, cmd, ProcArgsModifier(prefixCmd: prefixCmd, toAdd: toAdd, toRemove: toRemove,
        input: input, output: output, outputErr: outputErr,
        env: env, envModifier: envModifier, workingDir: workingDir,
        processName: processName, logFn: logFn, onErrorFn: onErrorFn), cancelFut)

proc runCheck*(sh: ProcArgs, cmd: seq[string], argsModifier: ProcArgsModifier,
cancelFut: Future[void] = nil): Future[bool] {.async.} =
    ## A sugar to combine `sh.start(...).wait(...).success` in a single call
    await(sh.start(cmd,
        argsModifier.merge(toRemove = (when defined(release):
            { MergeStderr, CaptureInput, CaptureOutputErr }
        else:
            { MergeStderr, CaptureInput }
        ))
    ).wait(cancelFut)).success

proc runCheck*(sh: ProcArgs, cmd: seq[string], prefixCmd = none(seq[string]), toAdd: set[ProcOption] = {}, toRemove: set[ProcOption] = {},
        input = none(AsyncIoBase), output = none(AsyncIoBase), outputErr = none(AsyncIoBase),
        env = none(ProcEnv), envModifier = none(ProcEnv), workingDir = none(string),
        processName = none(string), logFn = none(LogFn), onErrorFn = none(OnErrorFn), cancelFut: Future[void] = nil): Future[bool] =
    runCheck(sh, cmd, ProcArgsModifier(prefixCmd: prefixCmd, toAdd: toAdd, toRemove: toRemove,
        input: input, output: output, outputErr: outputErr,
        env: env, envModifier: envModifier, workingDir: workingDir,
        processName: processName, logFn: logFn, onErrorFn: onErrorFn), cancelFut)

proc runGetOutput*(sh: ProcArgs, cmd: seq[string], argsModifier: ProcArgsModifier,
cancelFut: Future[void] = nil): Future[string] {.async.} =
    ## A sugar to combine `withoutLineEnd await sh.runAssert(...).output` in a single call
    ## - Can raise ExecError if not successful
    ## - LineEnd is always stripped, because it is usually unawanted. Use sh.run if this comportement is not wanted
    ## - OutputErr stream is not included (removed in release mode, but captured in debug mode -> only show on error)
    withoutLineEnd await(sh.start(cmd,
        argsModifier.merge(
            toAdd = { CaptureOutput },
            toRemove = (when defined(release):
                { MergeStderr, CaptureInput, CaptureOutputErr }
            else:
                { MergeStderr, CaptureInput }
            )
    )).wait(cancelFut).assertSuccess()).output

proc runGetOutput*(sh: ProcArgs, cmd: seq[string], prefixCmd = none(seq[string]), toAdd: set[ProcOption] = {}, toRemove: set[ProcOption] = {},
        input = none(AsyncIoBase), output = none(AsyncIoBase), outputErr = none(AsyncIoBase),
        env = none(ProcEnv), envModifier = none(ProcEnv), workingDir = none(string),
        processName = none(string), logFn = none(LogFn), onErrorFn = none(OnErrorFn), cancelFut: Future[void] = nil): Future[string] =
    runGetOutput(sh, cmd, ProcArgsModifier(prefixCmd: prefixCmd, toAdd: toAdd, toRemove: toRemove,
        input: input, output: output, outputErr: outputErr,
        env: env, envModifier: envModifier, workingDir: workingDir,
        processName: processName, logFn: logFn, onErrorFn: onErrorFn), cancelFut)

proc runGetLines*(sh: ProcArgs, cmd: seq[string], argsModifier: ProcArgsModifier,
cancelFut: Future[void] = nil): Future[seq[string]] {.async.} =
    ## A sugar to combine `await splitLines sh.runGetOutput(...)` in a single call
    ## - Can raise ExecError if not successful
    ## - OutputErr stream is not included (removed in release mode, but captured in debug mode -> only show on error)
    splitLines withoutLineEnd await sh.runGetOutput(cmd, argsModifier)

proc runGetLines*(sh: ProcArgs, cmd: seq[string], prefixCmd = none(seq[string]), toAdd: set[ProcOption] = {}, toRemove: set[ProcOption] = {},
        input = none(AsyncIoBase), output = none(AsyncIoBase), outputErr = none(AsyncIoBase),
        env = none(ProcEnv), envModifier = none(ProcEnv), workingDir = none(string),
        processName = none(string), logFn = none(LogFn), onErrorFn = none(OnErrorFn), cancelFut: Future[void] = nil): Future[seq[string]] =
    runGetLines(sh, cmd, ProcArgsModifier(prefixCmd: prefixCmd, toAdd: toAdd, toRemove: toRemove,
        input: input, output: output, outputErr: outputErr,
        env: env, envModifier: envModifier, workingDir: workingDir,
        processName: processName, logFn: logFn, onErrorFn: onErrorFn), cancelFut)

proc runGetOutputStream*(sh: ProcArgs, cmd: seq[string], argsModifier: ProcArgsModifier,
cancelFut: Future[void] = nil): (AsyncIoBase, Future[void]) =
    ## A sugar doing this: `await splitLines sh.run(..., output = stream)` in a single call
    ## - Can raise ExecError if not successful
    ## - Second return value is a future that will be finished when the subprocess has been waited
    ## - OutputErr stream is not included (removed in release mode, but captured in debug mode -> only show on error)
    var pipe = AsyncPipe.new()
    var finishFut = sh.runDiscard(cmd,
        argsModifier.merge(
            toRemove = (when defined(release):
                    { MergeStderr, Interactive, CaptureOutput, CaptureInput, CaptureOutputErr }
                else:
                    { MergeStderr, Interactive, CaptureOutput, CaptureInput }
                ),
            output = some pipe.AsyncIoBase
    ), cancelFut)
    return (pipe.reader, finishFut)

proc runGetOutputStream*(sh: ProcArgs, cmd: seq[string], prefixCmd = none(seq[string]), toAdd: set[ProcOption] = {}, toRemove: set[ProcOption] = {},
        input = none(AsyncIoBase), output = none(AsyncIoBase), outputErr = none(AsyncIoBase),
        env = none(ProcEnv), envModifier = none(ProcEnv), workingDir = none(string),
        processName = none(string), logFn = none(LogFn), onErrorFn = none(OnErrorFn), cancelFut: Future[void] = nil): (AsyncIoBase, Future[void]) =
    runGetOutputStream(sh, cmd, ProcArgsModifier(prefixCmd: prefixCmd, toAdd: toAdd, toRemove: toRemove,
        input: input, output: output, outputErr: outputErr,
        env: env, envModifier: envModifier, workingDir: workingDir,
        processName: processName, logFn: logFn, onErrorFn: onErrorFn), cancelFut)

proc runGetStreams*(sh: ProcArgs, cmd: seq[string], argsModifier: ProcArgsModifier,
cancelFut: Future[void] = nil): (AsyncIoBase, AsyncIoBase, Future[void]) =
    ## - Similar to runGetOutputStream, but returns both output stream and outputErr stream
    ## - OutputErr stream is not included (removed in release mode, but captured in debug mode -> only show on error)
    var outputPipe = AsyncPipe.new()
    var outputErrPipe = AsyncPipe.new()
    var finishFut = sh.runDiscard(cmd,
        argsModifier.merge(
            toRemove = (when defined(release):
                    { MergeStderr, Interactive, CaptureOutput, CaptureInput, CaptureOutputErr }
                else:
                    { MergeStderr, Interactive, CaptureOutput, CaptureInput }
                ),
            output = some outputPipe.AsyncIoBase,
            outputErr = some outputErrPipe.AsyncIoBase
    ), cancelFut)
    return (outputPipe.reader, outputErrPipe.reader, finishFut)

proc runGetStreams*(sh: ProcArgs, cmd: seq[string], prefixCmd = none(seq[string]), toAdd: set[ProcOption] = {}, toRemove: set[ProcOption] = {},
        input = none(AsyncIoBase), output = none(AsyncIoBase), outputErr = none(AsyncIoBase),
        env = none(ProcEnv), envModifier = none(ProcEnv), workingDir = none(string),
        processName = none(string), logFn = none(LogFn), onErrorFn = none(OnErrorFn), cancelFut: Future[void] = nil): (AsyncIoBase, AsyncIoBase, Future[void]) =
    runGetStreams(sh, cmd, ProcArgsModifier(prefixCmd: prefixCmd, toAdd: toAdd, toRemove: toRemove,
        input: input, output: output, outputErr: outputErr,
        env: env, envModifier: envModifier, workingDir: workingDir,
        processName: processName, logFn: logFn, onErrorFn: onErrorFn), cancelFut)

proc askYesNo(sh: ProcArgs, text: string): bool =
    # A more complete version is available in myshellcmd/ui
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