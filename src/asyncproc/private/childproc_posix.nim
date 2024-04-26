import std/[os, exitprocs, posix, termios, bitops, options]
import std/[tables, strutils]
import asyncio, asyncio/[asyncpipe, asynctee]

import ./streamsbuilder


# Library
var PR_SET_PDEATHSIG {.importc, header: "<sys/prctl.h>".}: cint
proc prctl(option, argc2: cint): cint {.varargs, header: "<sys/prctl.h>".}
proc openpty(master, slave: var cint; slave_name: cstring, arg1, arg2: pointer): cint {.importc, header: "<pty.h>".}


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

proc toChildStream*(streamsBuilder: StreamsBuilder): tuple[
    passFds: seq[tuple[src: FileHandle, dest: FileHandle]],
    captures: tuple[input, output, outputErr: Future[string]],
    useFakePty: bool,
    afterSpawnCleanup: proc(),
    afterWaitCleanup: proc()
 ]
proc newPtyPair(): tuple[master, slave: AsyncFile]
proc newChildTerminalPair(): tuple[master, slave: AsyncFile]
proc restoreTerminal()
proc startProcess*(command: string, args: seq[string],
    passFds = defaultPassFds, env = initTable[string, string](),
    workingDir = "", daemon = false, fakePty = false): ChildProc
proc getPid*(p: ChildProc): int
proc running*(p: var ChildProc): bool
proc suspend*(p: ChildProc)
proc resume*(p: ChildProc)
proc terminate*(p: ChildProc)
proc kill*(p: ChildProc)
proc wait*(p: var ChildProc): int
proc waitImpl(p: var ChildProc, hang: bool)
proc envToCStringArray(t: Table[string, string]): cstringArray
proc readAll(fd: FileHandle): string


proc toChildStream*(streamsBuilder: StreamsBuilder): tuple[
    passFds: seq[tuple[src: FileHandle, dest: FileHandle]],
    captures: tuple[input, output, outputErr: Future[string]],
    useFakePty: bool,
    afterSpawnCleanup: proc(),
    afterWaitCleanup: proc()
 ] =
    var
        stdFiles: tuple[stdin, stdout, stderr: Asyncfile]
        captures: tuple[input, output, outputErr: Future[string]]
        useFakePty = false
        toClose: seq[AsyncIoBase]
        toCloseWhenFlushed: seq[AsyncIoBase]
        afterSpawnCleanup: proc()
        afterWaitCleanup: proc()
        closeEvent = newFuture[void]()
    if streamsBuilder.isInteractiveButNoInherit():
        useFakePty = true
        var
            (master, slave) = newChildTerminalPair()
            streams: tuple[stdin, stdout, stderr: AsyncIoBase]
        if MergeStderr in streamsBuilder.flags:
            (streams, captures, toClose, toCloseWhenFlushed) = streamsBuilder.buildToStreams()
            stdFiles.stdin = slave
            stdFiles.stdout = slave
            stdFiles.stderr = slave
            discard streams.stdin.transfer(master, closeEvent)
            discard master.transfer(streams.stdout)
            afterSpawnCleanup = (proc() =
                slave.close
            )
            afterWaitCleanup = (proc() =
                closeEvent.complete()
                master.closeWhenFlushed()
                for stream in toCloseWhenFlushed:
                    stream.closeWhenFlushed()
                for stream in toClose:
                    stream.close()
                restoreTerminal()
            )
        else:
            raise newException(AssertionDefect, "Not implemented yet")
            #[
            streamsBuilder.flags.excl InteractiveOut
            (streams, captures, ownedStreams, transferWaiters) = streamsBuilder.buildToStreams()
            var stdoutCapture: AsyncIoBase
            if streams.stdout of AsyncPipe:
                transferWaiters.add streams.stdout.transfer(slave)
                stdFiles.stdout = AsyncPipe(streams.stdout).writer
            else:
                var pipe = AsyncPipe.new()
                stdFiles.stdout = pipe.writer
                stdoutCapture = AsyncTeeReader.new(pipe.reader, streams.stdout)
                ownedStreams.add pipe
            var stderrCapture: AsyncIoBase
            if streams.stderr of AsyncPipe:
                transferWaiters.add streams.stderr.transfer(slave)
                stdFiles.stdout = AsyncPipe(streams.stderr).writer
            else:
                var pipe = AsyncPipe.new()
                stdFiles.stderr = pipe.writer
                stderrCapture = AsyncTeeReader.new(pipe.reader, streams.stderr)
                ownedStreams.add pipe
            transferWaiters.add stdoutCapture.transfer(slave)
            transferWaiters.add stderrCapture.transfer(slave)

            stdFiles.stdin = slave
            transferWaiters.add streams.stdin.transfer(master, closeEvent)
            transferWaiters.add master.transfer(stderrAsync, closeEvent)
            afterSpawnCleanup = (proc() =
                ownedStreams.closeIfFound(stdFiles.stdout)
                ownedStreams.closeIfFound(stdFiles.stderr)
            )
            afterWaitCleanup = (proc() {.closure.} =
                closeEvent.complete()
                slave.close()
                master.close()
                for stream in ownedStreams:
                    stream.closeWhenFlushed()
                restoreTerminal()
            )
            ]#
    else:
        (stdFiles, captures, toClose, toCloseWhenFlushed) = streamsBuilder.buildToChildFile(closeEvent)
        afterSpawnCleanup = (proc() =
            if stdFiles.stdin != nil: stdFiles.stdin.close()
            if stdFiles.stdout != nil: stdFiles.stdout.close()
            if stdFiles.stderr != nil: stdFiles.stderr.close()
        )
        afterWaitCleanup = (proc() =
            closeEvent.complete()
            for stream in toCloseWhenFlushed:
                stream.closeWhenFlushed()
            for stream in toClose:
                stream.close()
        )
    return (
        toPassFds(stdFiles.stdin, stdFiles.stdout, stdFiles.stderr),
        captures,
        useFakePty,
        afterSpawnCleanup,
        afterWaitCleanup,
    )

proc newChildTerminalPair(): tuple[master, slave: AsyncFile] =
    if TermiosBackup.isNone():
        TermiosBackup = some Termios()
        if tcGetAttr(STDIN_FILENO, addr TermiosBackup.get()) == -1: raiseOSError(osLastError())
        addExitProc(proc() = restoreTerminal())        
    var newParentTermios: Termios
    # Make the parent raw
    newParentTermios = TermiosBackup.get()
    newParentTermios.c_lflag.clearMask(ICANON)
    newParentTermios.c_lflag.clearMask(ISIG)
    newParentTermios.c_lflag.clearMask(ECHO)
    newParentTermios.c_cc[VMIN] = 1.char
    newParentTermios.c_cc[VTIME] = 0.char
    if tcsetattr(STDIN_FILENO, TCSANOW, addr newParentTermios) == -1: raiseOSError(osLastError())
    return newPtyPair()

proc newPtyPair(): tuple[master, slave: AsyncFile] =
    var master, slave: cint
    # default termios param shall be ok
    if openpty(master, slave, nil, nil, nil) == -1: raiseOSError(osLastError())
    return (AsyncFile.new(master), AsyncFile.new(slave))

proc restoreTerminal() =
    if TermiosBackup.isSome():
        if tcsetattr(STDIN_FILENO, TCSANOW, addr TermiosBackup.get()) == -1:
            raiseOSError(osLastError())

proc startProcess*(command: string, args: seq[string],
passFds = defaultPassFds, env = initTable[string, string](),
workingDir = "", daemon = false, fakePty = false): ChildProc =
    ##[
        args:
            - args[0] should be the process name. Not providing it result in undefined behaviour
        env:
            - if env is nil, use parent process
        file_descriptors:
            - parent process is responsible for creating and closing its pipes ends
        daemonize:
            if false: will be closed with parent process
            else: will survive (but no action on fds is done)
    ]##
    var fdstoKeep = newSeq[FileHandle](passFds.len())
    for (src, dest) in passFds:
        fdstoKeep.add dest
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
            if workingDir.len > 0'i32:
                setCurrentDir(workingDir)
            
            # IO handling
            for (src, dest) in passFds:
                if src != dest:
                    let exitCode = dup2(src, dest)
                    if exitCode < 0'i32: raiseOSError(osLastError())
            for (_, file) in walkDir("/proc/" & $childPid & "/fd/", relative = true):
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

proc wait*(p: var ChildProc): int =
    ## Without it, the pid won't be recycled
    ## Block main thread
    p.waitImpl(true)
    return p.exitCode    

proc waitImpl(p: var ChildProc, hang: bool) =
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
