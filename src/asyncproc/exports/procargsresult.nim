import std/[options, strutils, sequtils]
from std/os import quoteShell

import asyncio
import aloganimisc/[deep, strmisc]

import ./procenv {.all.}

export quoteShell, options

# It has been decided to rely heavily on Options for finer user control and simplicity of implementation

type
    ProcOption* = enum
        ##[
        ### Daemon
        The childproc will not be killed with its parent and continue to live afterwards
        
        ### QuoteArgs
        - ensure command arguments are arguments and not code
        - Essential if arguments come from user input
        - If you don't use it, please use quoteShell function to sanitize input
        - Not called if prefixCmd is not set, because posix exec can only accept arguments

        ### IgnoreInterrupt (low level option)
        Ctrl-c (SIGINT on linux) on foreground process (either by using Interactive or input = stdinAsync) will don't kill the process

        ### Interactive
        * First: parent's streams will be added to input/output/outputErr of child
            * This will not affect Capture options.
            * This will not affect that user can also set child input/output/outpterr (which will take priority):
                * if user set input, it will result in AsyncChainReader.new(userInput, stdinAsync)
                * if user set output/outputErr, it will result in AsyncTeeWriter.new(userInput, stdout/stderrAsync)
        * Secondly: it will ensure (on posix) that childproc stdin act as a fake terminal if needed (mandatory for repls like bash, python, etc)
            - only if custom input has been defined or CaptureInput is set
            - might not be as stable as using directly stdin
            

        ### MergeStderr
        - Output and OutputErr will designate the same pipe, ensuring the final output is ordered chronogically
        - Not having outputErr makes error less explicit

        ### RegisterProcess
        Put the spawn process in a global variable named RunningProcesses until it is waited. Useful for tracking or global Process manipulation

        ### SetEnvOnCmdLine (low level option)
        - Instead of giving childProc an environment, it will be given an empty environment
        - And env will be put on commandline. eg: `@["ssh", "user@localhost", "export MYVAR=MYVAL MYVAR2=MYVAL2; command"]`
        ]##
        AskConfirmation,
        CaptureInput, CaptureOutput, CaptureOutputErr,
        Daemon, DryRun, IgnoreInterrupt, Interactive,
        KeepStreamOpen, MergeStderr,
        QuoteArgs, NoParentEnv, RegisterProcess,
        SetEnvOnCmdLine, ShowCommand, WithLogging,


const defaultRunFlags = {QuoteArgs, ShowCommand, Interactive, CaptureOutput,
        CaptureOutputErr, WithLogging}

type
    ProcResult* = ref object
        ## Data structures containing all informations captured.
        ## fullCmd includes procArgs.prefixCmd, whereas cmd don't
        fullCmd*: seq[string]
        cmd*: seq[string]
        output*: string
        outputErr*: string
        input*: string
        success*: bool
        exitCode*: int
        procArgs*: ProcArgs
        onErrorFn: OnErrorFn

    ExecError* = OSError
    ## ExecError can only be raised when assertSuccess is used (or any run function relying on it)

    LogFn* = proc(res: ProcResult)
    OnErrorFn* = proc(res: ProcResult): Future[ProcResult]

    ProcArgs* = ref object
        ##[
        ### prefixCmd
        Command that is put before the actual command being run. Must be capable of evaluating a command, like:
        - `@["sh", "-c"]`
        - `@["chroot", "path"]`
        - `@["ssh, "address"]`
        ### options
        All the high level tweaking available for the childProcess
        ### env
        If isNone, parent's env will be used, otherwise, will be used even if empty (resulting in no env)
        ### processName
        The name of the process as it will be available in ps/top commands. Not very useful. Doesn't hide the arguments.
        ### logFn
        This proc will be called only if WithLogging option is set and after childproc have been awaited, no matter if result is success or not
        ### onErrorFn
        This proc will be called if childproc quit with an error code and assertSucces is called
            (or any function calling it like runAssert, runGetOutput, etc)
        ### input, output, outputErr:
        - low level arguments to fine tweak child standard streams. Try to use options if possible
        - it could be any stream defined in mylib/asyncio
        - if closeWhenOver option is set to true and ProcArgs is used multile times,
            will create a deceptive behaviour (non zero exit on child proc which need streams)
        - deepCopy ProcArgs will have little effect on those arguments if they are associated with FileHandle
            (eg: AsyncFile, AsyncPipe, stdinAsync, etc) because FileHandle is a global value

        deepCopy is the way to go to create a new ProcArgs with same argument
        ]##
        prefixCmd* = newSeq[string]()
        options* = defaultRunFlags
        env*: ProcEnv
        workingDir* = ""
        processName* = ""
        logFn*: LogFn
        onErrorFn*: OnErrorFn
        input*: AsyncIoBase
        output*: AsyncIoBase
        outputErr*: AsyncIoBase

    ProcArgsModifier* = object
        ##[
        Utility struct to help modify ProcArgs in a API-like way/functional style, while maintaining fine control and explicitness
        
        .. warning:: Option is very picky on the types given
            - to pass a stream, be sure, to cast it to AsyncIoBase, eg: `some AsyncString.new("data").AsyncIoBase`
            - to pass a callback, be sure to cast it to the appropriate function, eg: `some LogFn(proc(res: ProcResult) = ...)`
        ]##
        prefixCmd*: Option[seq[string]]
        toAdd*: set[ProcOption]
        toRemove*: set[ProcOption]
        input*: Option[AsyncIoBase]
        output*: Option[AsyncIoBase]
        outputErr*: Option[AsyncIoBase]
        env*: Option[ProcEnv] ## replace the original one
        envModifier*: Option[ProcEnv]
        ## envModifier don't replace the original one, but is merged with it
        workingDir*: Option[string]
        processName*: Option[string]
        logFn*: Option[LogFn]
        onErrorFn*: Option[OnErrorFn]


let
    sh* = ProcArgs() ## Default ProcArgs object to avoid final user to create a ProcArg. Shall not be modified directly but copied rather
    internalCmd* = when defined(release):
            ProcArgsModifier(toRemove: {Interactive, MergeStderr, ShowCommand,
                    CaptureInput, CaptureOutput, CaptureOutputErr})
        else:
            ProcArgsModifier(toAdd: {CaptureOutputErr}, toRemove: {Interactive,
                    MergeStderr, ShowCommand, CaptureInput, CaptureOutput})
    ## A ProcArgsModifier that adjust default flags for unimportant or common commands by suppressing echoing, interactivness and error capture

proc deepCopy*(self: ProcArgs): ProcArgs =
    deep.deepCopy(result, self)

proc merge*(procArgs: ProcArgs, modifier: ProcArgsModifier): ProcArgs =
    ProcArgs(
        prefixCmd: if modifier.prefixCmd.isSome: modifier.prefixCmd.get(
                ) else: procArgs.prefixCmd,
        options: procArgs.options + modifier.toAdd - modifier.toRemove,
        input: if modifier.input.isSome: modifier.input.get(
                ) else: procArgs.input,
        output: if modifier.output.isSome: modifier.output.get(
                ) else: procArgs.output,
        outputErr: if modifier.outputErr.isSome: modifier.outputErr.get(
                ) else: procArgs.outputErr,
        env: (if modifier.env.isSome:
                if modifier.envModifier.isSome():
                    mergeEnv(modifier.env.get(), modifier.envModifier.get())
                else:
                    modifier.env.get()
            else:
                if modifier.envModifier.isSome():
                    mergeEnv(procArgs.env, modifier.envModifier.get())
                else:
                    procArgs.env
            ),
        workingDir: if modifier.workingDir.isSome: modifier.workingDir.get(
                ) else: procArgs.workingDir,
        processName: if modifier.processName.isSome: modifier.processName.get(
                ) else: procArgs.processName,
        logFn: if modifier.logFn.isSome: modifier.logFn.get(
                ) else: procArgs.logFn,
        onErrorFn: if modifier.onErrorFn.isSome: modifier.onErrorFn.get(
                ) else: procArgs.onErrorFn,
    )

proc merge*(a, b: ProcArgsModifier): ProcArgsModifier =
    ProcArgsModifier(
        prefixCmd: if b.prefixCmd.isSome: b.prefixCmd else: a.prefixCmd,
        toAdd: a.toAdd + b.toAdd, # options to remove take priority
        toRemove: (a.toRemove - b.toAdd) + b.toRemove,
        input: if b.input.isSome: b.input else: a.input,
        output: if b.output.isSome: b.output else: a.output,
        outputErr: if b.outputErr.isSome: b.outputErr else: a.outputErr,
        env: (if b.env.isSome:
                if a.env.isSome:
                    some(mergeEnv(a.env.get(), b.env.get()))
                else:
                    b.env
            else:
                a.env),
                envModifier: (if b.envModifier.isSome:
                if a.envModifier.isSome:
                    some(mergeEnv(a.envModifier.get(), b.envModifier.get()))
                else:
                    b.envModifier
            else:
                a.envModifier),
        workingDir: if b.workingDir.isSome: b.workingDir else: a.workingDir,
        processName: if b.processName.isSome: b.processName else: a.processName,
        logFn: if b.logFn.isSome: b.logFn else: a.logFn,
        onErrorFn: if b.onErrorFn.isSome: b.onErrorFn else: a.onErrorFn,
    )

proc merge*[T: ProcArgs or ProcArgsModifier](a: T,
            prefixCmd = none(seq[string]),
            toAdd: set[ProcOption] = {},
            toRemove: set[ProcOption] = {},
            input = none(AsyncIoBase),
            output = none(AsyncIoBase),
            outputErr = none(AsyncIoBase),
            env = none(ProcEnv),
            envModifier = none(ProcEnv),
            workingDir = none(string),
            processName = none(string),
            logFn = none(LogFn),
            onErrorFn = none(OnErrorFn)
            ): T =
    a.merge(
        ProcArgsModifier(
            prefixCmd: prefixCmd,
            toAdd: toAdd,
            toRemove: toRemove,
            input: input,
            output: output,
            outputErr: outputErr,
            env: env,
            envModifier: envModifier,
            workingDir: workingDir,
            processName: processName,
            logFn: logFn,
            onErrorFn: onErrorFn,
        )
    )

proc buildCommand(procArgs: ProcArgs, postfixCmd: seq[string]): seq[
        string] {.used.} =
    if procArgs.prefixCmd.len() == 0:
        if SetEnvOnCmdLine in procArgs.options:
            raise newException(OsError, "Can't apply " & $SetEnvOnCmdLine & " option if not prefixCmd has been given")
        # No quotation needed in this case
        return postfixCmd
    result.add procArgs.prefixCmd
    var stringCmd: string
    stringCmd.add (
        if SetEnvOnCmdLine in procArgs.options:
        (if NoParentEnv in procArgs.options:
            procArgs.env
        else:
            newEnvFromParent().mergeEnv(procArgs.env)
        ).toShellFormat(QuoteArgs in procArgs.options)
    else: ""
    )
    stringCmd.add (if QuoteArgs in procArgs.options:
        postfixCmd.map(proc(arg: string): string = quoteShell(arg))
    else:
        postfixCmd
    ).join(" ")
    result.add stringCmd

proc formatErrorMsg*(procResult: ProcResult): string =
    ## Convenience method to transform procResult in human readable form
    ## Tails errorOutput
    let errData = tail(10, if procResult.outputErr != "":
            procResult.outputErr
        else:
            procResult.output)
    return "## ProcResult: " & $procResult.fullCmd &
        "\nExitCode: " & $procResult.exitCode & (if errData == "":
            ""
        else:
            "\n*** COMMAND DATA TAIL ***\n" & errData.repr() &
            "\n*** END OF DATA ***\n"
        )

proc pretty*(procResult: ProcResult): string =
    ## To format it more human readable. Subject to change
    return "## ProcResult: " & $procResult.fullCmd &
        "\n- Input: " & procResult.input.repr() &
        "\n- Output: " & procResult.output.repr() &
        "\n- OutputErr: " & procResult.outputErr.repr()

proc assertSuccess*(res: Future[ProcResult]): Future[ProcResult] {.async.} =
    ## If ProcResult is unsuccessful, try to replace it by OnErrorFn callback
    ## If onErrorFn is unsuccessful or doesn't exists, raise an ExecError
    let awaitedResult = await res
    if awaitedResult.success:
        return awaitedResult
    elif awaitedResult.onErrorFn != nil:
        let newProcResult = await awaitedResult.onErrorFn(awaitedResult)
        if newProcResult.success:
            return newProcResult
    raise newException(ExecError, awaitedResult.formatErrorMsg())

proc merge*(allResults: varargs[ProcResult]): ProcResult =
    ## Add together captured streams, keep the max exitCode
    ## If one result is not a success, all while be unsuccessful
    ## But discard following args: options, onErrorFn
    result = ProcResult()
    var length: int

    length = allResults.len() - 1 # separator
    for i in 0..high(allResults): inc(length, allResults[i].fullCmd.len())
    result.fullCmd = newSeqofCap[string](length)
    result.fullCmd.add allResults[0].fullCmd
    for i in 1..high(allResults):
        result.fullCmd.add allResults[i].fullCmd
        result.fullCmd.add "\n"

    for i in 0..high(allResults): inc(length, allResults[i].cmd.len())
    result.cmd = newSeqofCap[string](length)
    result.cmd.add allResults[0].cmd
    for i in 1..high(allResults):
        result.cmd.add allResults[i].cmd
        result.cmd.add "\n"

    length = allResults.len() - 1 # separator
    for i in 0..high(allResults): inc(length, allResults[i].output.len())
    result.output = newStringOfCap(length)
    result.output.add allResults[0].output
    for i in 1..high(allResults):
        result.output.add allResults[i].output
        result.output.add "\n"

    length = allResults.len() - 1 # separator
    for i in 0..high(allResults): inc(length, allResults[i].outputErr.len())
    result.outputErr = newStringOfCap(length)
    result.outputErr.add allResults[0].outputErr
    for i in 1..high(allResults):
        result.outputErr.add allResults[i].outputErr
        result.outputErr.add "\n"

    length = allResults.len() - 1 # separator
    for i in 0..high(allResults): inc(length, allResults[i].input.len())
    result.input = newStringOfCap(length)
    result.input.add allResults[0].input
    for i in 1..high(allResults):
        result.input.add allResults[i].input
        result.input.add "\n"

    result.exitCode = foldl(allResults, max(a, b.exitCode), 0)
    result.success = result.exitCode != 0

proc withoutLineEnd*(s: string): string =
    result = s
    result.stripLineEnd()

proc setOnErrorFn(self: ProcResult, onErrorFn: OnErrorFn) {.used.} =
    self.onErrorFn = onErrorFn
