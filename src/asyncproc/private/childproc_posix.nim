import std/[os, exitprocs, posix, termios, bitops, options]
import std/[tables, strutils]
import asyncio

import ../exports/procargsresult {.all.}

## SIGINT is ignored in main process, preventing it from being accidentally killed
## warning..:
##      when using `nim r program.nim`, program.nim is a child process of choosenim and is catched by choosenim
##      https://github.com/nim-lang/Nim/issues/23573
onSignal(SIGINT):
    discard sig

# Library
var PR_SET_PDEATHSIG {.importc, header: "<sys/prctl.h>".}: cint
proc prctl(option, argc2: cint): cint {.varargs, header: "<sys/prctl.h>".}
proc openpty(master, slave: var cint; slave_name: cstring; arg1,
        arg2: pointer): cint {.importc, header: "<pty.h>".}


type ChildProc* = object
    pid*: Pid
    exitCode*: cint
    hasExited*: bool
    cleanUps: seq[proc()]

const defaultPassFds = @[
    (src: FileHandle(0), dest: FileHandle(0)),
    (src: FileHandle(1), dest: FileHandle(1)),
    (src: FileHandle(2), dest: FileHandle(2)),
]

var TermiosBackup: Option[Termios]

proc waitImpl(p: var ChildProc; hang: bool) =
    if p.hasExited:
        return
    var status: cint
    let errorCode = waitpid(p.pid, status, if hang: 0 else: WNOHANG)
    if errorCode == p.pid:
        if WIFEXITED(status) or WIFSIGNALED(status):
            p.hasExited = true
            p.exitCode = WEXITSTATUS(status)
    elif errorCode == 0'i32:
        discard ## Assume the process is still up and running
    else:
        raiseOSError(osLastError())

proc wait*(p: var ChildProc): int =
    ## Without it, the pid won't be recycled
    ## Block main thread
    p.waitImpl(true)
    return p.exitCode

proc getPid*(p: ChildProc): int =
    p.pid

proc running*(p: var ChildProc): bool =
    p.waitImpl(false)
    return not p.hasExited

proc suspend*(p: ChildProc) =
    if posix.kill(p.pid, SIGSTOP) != 0'i32: raiseOSError(osLastError())

proc resume*(p: ChildProc) =
    if posix.kill(p.pid, SIGCONT) != 0'i32: raiseOSError(osLastError())

proc terminate*(p: ChildProc) =
    if posix.kill(p.pid, SIGTERM) != 0'i32: raiseOSError(osLastError())

proc kill*(p: ChildProc) =
    if posix.kill(p.pid, SIGKILL) != 0'i32: raiseOSError(osLastError())

proc envToCStringArray(t: Table[string, string]): cstringArray =
    ## from std/osproc
    result = cast[cstringArray](alloc0((t.len + 1) * sizeof(cstring)))
    var i = 0
    for key, val in pairs(t):
        var x = key & "=" & val
        result[i] = cast[cstring](alloc(x.len+1))
        copyMem(result[i], addr(x[0]), x.len+1)
        inc(i)

proc readAll(fd: FileHandle): string =
    let bufferSize = 1024
    result = newString(bufferSize)
    var totalCount: int
    while true:
        let bytesCount = posix.read(fd, addr(result[totalCount]), bufferSize)
        if bytesCount == 0:
            break
        totalCount += bytesCount
        result.setLen(totalCount + bufferSize)
    result.setLen(totalCount)


proc startProcess*(command: string; args: seq[string];
passFds = defaultPassFds; env = initTable[string, string]();
workingDir = ""; daemon = false; fakePty = false;
ignoreInterrupt = false): ChildProc =
    ##[
        ### args
        args[0] should be the process name. Not providing it result in undefined behaviour
        ### env
        if env is nil, use parent process
        ### file_descriptors
        parent process is responsible for creating and closing its pipes ends
        ### daemonize
        if false: will be closed with parent process
        else: will survive (but no action on fds is done)
    ]##
    var fdstoKeep = newSeq[FileHandle](passFds.len())
    for i in 0..high(passFds):
        fdstoKeep[i] = passFds[i][1]
    # Nim objects to C objects
    var sysArgs = allocCStringArray(args)
    defer: deallocCStringArray(sysArgs)
    var sysEnv = envToCStringArray(env)
    defer: (if sysEnv != nil: deallocCStringArray(sysEnv))
    # Error pipe for catching inside child
    var errorPipes: array[2, cint]
    if pipe(errorPipes) != 0'i32:
        raiseOSError(osLastError())
    let ppidBeforeFork = getCurrentProcessId()
    let pid = fork()
    if pid == 0'i32: # Child
        try:
            var childPid = getCurrentProcessId()
            # Working dir
            if workingDir.len > 0'i32:
                setCurrentDir(workingDir)
            # IO handling
            for (src, dest) in passFds:
                if src != dest:
                    let exitCode = dup2(src, dest)
                    if exitCode < 0'i32: raiseOSError(osLastError())
            for (_, file) in walkDir("/proc/" & $childPid & "/fd/",
                    relative = true):
                let fd = file.parseInt().cint
                if fd notin fdstoKeep and fd != errorPipes[1]:
                    discard close(fd)
            # Daemon
            if fakePty and not daemon:
                if setsid() < 0'i32: raiseOSError(osLastError())
            elif daemon:
                # recommanded to close standard fds
                discard umask(0)
                if setsid() < 0'i32: raiseOSError(osLastError())
                signal(SIGHUP, SIG_IGN)
            else:
                let exitCode = prctl(PR_SET_PDEATHSIG, SIGHUP)
                if exitCode < 0'i32 or getppid() != ppidBeforeFork:
                    exitnow(1)
            # Misc
            if ignoreInterrupt:
                signal(SIGINT, SIG_IGN)
            discard close(errorPipes[1])
        except:
            let errMsg = getCurrentExceptionMsg()
            discard write(errorPipes[1], addr(errMsg[0]), errMsg.len())
            discard close(errorPipes[1]) # Could have been using fnctl FD_CLOEXEC
            exitnow(1)
            # Should be safe (or too hard to catch) from here
            # Exec
        when defined(uClibc) or defined(linux) or defined(haiku):
            let exe = findExe(command)
            if sysEnv != nil:
                discard execve(exe.cstring, sysArgs, sysEnv)
            else:
                discard execv(exe.cstring, sysArgs)
        else: # MacOs mainly
            if sysEnv != nil:
                var environ {.importc.}: cstringArray
                environ = sysEnv
            discard execvp(command.cstring, sysArgs)
        exitnow(1)

    # Child error handling
    if pid < 0: raiseOSError(osLastError())
    discard close(errorPipes[1])
    var errorMsg = readAll(errorPipes[0])
    discard close(errorPipes[0])
    if errorMsg.len() != 0: raise newException(OSError, errorMsg)
    return ChildProc(pid: pid, hasExited: false)

proc newPtyPair(): tuple[master, slave: AsyncFile] =
    var master, slave: cint
    # default termios param shall be ok
    if openpty(master, slave, nil, nil, nil) == -1: raiseOSError(osLastError())
    return (AsyncFile.new(master), AsyncFile.new(slave))

proc restoreTerminal() =
    if TermiosBackup.isSome():
        if tcsetattr(STDIN_FILENO, TCSANOW, addr TermiosBackup.get()) == -1:
            raiseOSError(osLastError())

proc newChildTerminalPair(): tuple[master, slave: AsyncFile] =
    if TermiosBackup.isNone():
        TermiosBackup = some Termios()
        if tcGetAttr(STDIN_FILENO, addr TermiosBackup.get()) ==
                -1: raiseOSError(osLastError())
        addExitProc(proc() = restoreTerminal())
    var newParentTermios: Termios
    # Make the parent raw
    newParentTermios = TermiosBackup.get()
    newParentTermios.c_lflag.clearMask(ICANON)
    newParentTermios.c_lflag.clearMask(ISIG)
    newParentTermios.c_lflag.clearMask(ECHO)
    newParentTermios.c_cc[VMIN] = 1.char
    newParentTermios.c_cc[VTIME] = 0.char
    if tcsetattr(STDIN_FILENO, TCSANOW, addr newParentTermios) ==
            -1: raiseOSError(osLastError())
    return newPtyPair()

proc buildStreamsAndSpawn*(procArgs: ProcArgs, closeEvent: Future[void],
        command, processName: string;
        args: seq[string]; ## Not including process name
        env: Table[string, string]
    ): tuple[
            childProc: ChildProc;
            stdinCapture, stdoutCapture, stderrCapture: AsyncIoBase;
            flushedEvent: Future[void];
        ] =
    # Many methods are possible to build the streams
    # To ensure readability, maintanability, etc. The dumbest and most imperative solution is choosen
    var flushedEvents: seq[Future[void]]
    var ptyPair: tuple[master, slave: AsyncFile] = (nil, nil)
    var useFakePty = false
    
    #[ Build Stdin ]#
    var stdinChild: AsyncFile
    var stdinCapture: AsyncIoBase
    if Interactive notin procArgs.options and procArgs.input == nil:
        stdinChild = nil
    elif Interactive notin procArgs.options and CaptureInput notin procArgs.options:
        if procArgs.input of AsyncFile:
            stdinChild = AsyncFile(procArgs.input)
        else:
            let pipe = AsyncPipe.new()
            stdinChild = pipe.writer
            transfer(procArgs.input, pipe.reader, closeEvent).addCallback(
                proc() = pipe.reader.close()
            )
    elif Interactive notin procArgs.options and CaptureInput in procArgs.options:
        let pipe = AsyncPipe.new()
        let capture = AsyncStream.new()
        stdinChild = pipe.reader
        stdinCapture = capture.reader
        transfer(
            AsyncTeeReader.new(procArgs.input, capture.writer),
            pipe.writer,
            closeEvent
            ).addCallback(proc() =
                pipe.writer.close()
                capture.writer.close()
            )
    elif Interactive in procArgs.options and CaptureInput notin procArgs.options and procArgs.input == nil:
        stdinChild = stdinAsync
    elif Interactive in procArgs.options and (CaptureInput in procArgs.options or procArgs.input != nil):
        ptyPair = newChildTerminalPair()
        useFakePty = true
        var newInput: AsyncIoBase
        if procArgs.input != nil and CaptureInput notin procArgs.options:
            newInput = AsyncChainReader.new(procArgs.input, stdinAsync)
        elif procArgs.input == nil and CaptureInput in procArgs.options:
            var capture = AsyncStream.new()
            newInput = AsyncTeeReader.new(stdinAsync, capture.writer)
            closeEvent.addCallback(proc() = capture.reader.close())
        elif procArgs.input != nil and CaptureInput in procArgs.options:
            var capture = AsyncStream.new()
            newInput = AsyncTeeReader.new(
                AsyncChainReader.new(procArgs.input, stdinAsync), capture.writer
            )
            closeEvent.addCallback(proc() = capture.reader.close())
        discard transfer(newInput, ptyPair.master, closeEvent)
    
    #[ Build Stdout/Stderr Commons ]#
    proc builtOutStream(outStream: AsyncIoBase, captureFlag: bool,
            childStream: var AsyncFile, captureStream: var AsyncIoBase) =
        if Interactive notin procArgs.options and outStream == nil:
            childStream = nil
        elif Interactive notin procArgs.options and not captureFlag:
            if outStream of AsyncFile:
                childStream = AsyncFile(outStream)
            else:
                let pipe = AsyncPipe.new()
                childStream = pipe.reader
                flushedEvents.add transfer(pipe.writer, outStream, closeEvent).then(
                    proc(): Future[void] =
                        pipe.writer.close()
                        return newCompletedFuture()
                )
        elif Interactive notin procArgs.options and captureFlag:
            let pipe = AsyncPipe.new()
            let capture = AsyncStream.new()
            childStream = pipe.writer
            captureStream = capture.reader
            flushedEvents.add transfer(pipe.reader, outStream, closeEvent
                ).then(proc(): Future[void] =
                    pipe.reader.close()
                    capture.writer.close()
                    return newCompletedFuture()
            )
    proc makeInteractive(outStream, parentStream: AsyncIoBase, captureFlag: bool, closeEvent: Future[void]): AsyncIoBase =
        if outStream != nil and not captureFlag:
            return AsyncTeeWriter.new(outStream, parentStream)
        elif outStream == nil and captureFlag:
            var capture = AsyncStream.new()
            var newOutStream = AsyncTeeWriter.new(outStream, capture)
            closeEvent.addCallback(proc() = capture.reader.close())
            return newOutStream
        elif outStream != nil and captureFlag:
            var capture = AsyncStream.new()
            var newOutStream = AsyncTeeWriter.new(
                outStream, parentStream, capture.writer
            )
            closeEvent.addCallback(proc() = capture.reader.close())
            return newOutStream

    #[ Build Stdout/Stderr ]#
    var stdoutChild, stderrChild: AsyncFile
    var stdoutCapture, stderrCapture: AsyncIoBase
    if ptyPair.master == nil and MergeStderr in procArgs.options:
        builtOutStream(procArgs.output, CaptureOutput in procArgs.options, stdoutChild, stdoutCapture)
        stderrChild = stdoutChild
    elif ptyPair.master == nil and MergeStderr notin procArgs.options:
        builtOutStream(AsyncTeeWriter.new(procArgs.output, AsyncIoDelayed.new(stdoutAsync, 1)),
            CaptureOutput in procArgs.options, stdoutChild, stdoutCapture)
        builtOutStream(AsyncTeeWriter.new(procArgs.outputErr, AsyncIoDelayed.new(stdoutAsync, 1)),
            CaptureOutputErr in procArgs.options, stderrChild, stderrCapture)
    elif ptyPair.master != nil and MergeStderr in procArgs.options:
        stdoutChild = ptyPair.slave
        stderrChild = ptyPair.slave
        var newOutput = makeInteractive(procArgs.output, stdoutAsync, CaptureOutput in procArgs.options, closeEvent)
        flushedEvents.add transfer(ptyPair.master, newOutput).then(
            proc(): Future[void] =
                ptyPair.master.close()
                restoreTerminal()
                return newCompletedFuture()
        )            
    elif ptyPair.master != nil and MergeStderr notin procArgs.options:
        var newOutput = makeInteractive(procArgs.output, AsyncIoDelayed.new(stdoutAsync, 1),
            CaptureOutput in procArgs.options, closeEvent)
        var newOutputErr = makeInteractive(procArgs.outputErr, AsyncIoDelayed.new(stderrAsync, 2),
            CaptureOutputErr in procArgs.options, closeEvent)
        var pipeOut = AsyncPipe.new()
        var pipeErr = AsyncPipe.new()
        stdoutChild = pipeOut.writer
        stderrChild = pipeErr.writer
        flushedEvents.add (
                transfer(pipeOut.reader, newOutput) and
                transfer(pipeErr.reader, newOutputErr)
            ).then(
                proc() {.async.} =
                    await stdoutCapture.clear() and stderrCapture.clear()
                    ptyPair.slave.close()
                    stdoutCapture.close()
                    stderrCapture.close()
                )
        flushedEvents.add transfer(ptyPair.master, stdoutAsync).then(
            proc(): Future[void] =
                ptyPair.master.close()
                restoreTerminal()
                return newCompletedFuture()
            )

    #[ Spawn ChildProc ]#
    var passFds: seq[(FileHandle, FileHandle)]
    if stdinChild != nil:
        passFds.add (stdinChild.fd, STDIN_FILENO.FileHandle)
    if stdoutChild != nil:
        passFds.add (stdoutChild.fd, STDOUT_FILENO.FileHandle)
    if stderrChild != nil:
        passFds.add (stderrChild.fd, STDERR_FILENO.FileHandle)
    let childProc = startProcess(command, processName & args,
        passFds, env, procArgs.workingDir,
        Daemon in procArgs.options, fakePty = useFakePty, IgnoreInterrupt in procArgs.options)
    if stdinChild != nil: stdinChild.close()
    if stdoutChild != nil: stdoutChild.close()
    if stderrChild != nil: stderrChild.close()
    return (
        childProc,
        stdinCapture, stdoutCapture, stderrCapture,
        all(flushedEvents)
    )