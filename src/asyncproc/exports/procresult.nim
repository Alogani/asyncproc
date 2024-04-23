import std/[strutils, sequtils]
import aloganimisc/strmisc


type
    ExecError* = OSError

    ProcResult* = ref object
        cmd*: seq[string]
        output*: string
        outputErr*: string
        input*: string
        success*: bool
        exitCode*: int
        onErrorFn: OnErrorFn

    OnErrorFn* = proc(res: ProcResult): ProcResult

proc assertSuccess*(self: ProcResult): ProcResult {.discardable.}
proc merge*(allResults: varargs[ProcResult]): ProcResult
proc withoutLineEnd*(s: string): string
proc setOnErrorFn(self: ProcResult, onErrorFn: OnErrorFn) {.used.}


proc assertSuccess*(self: ProcResult): ProcResult =
    if self.success:
        return self
    elif self.onErrorFn != nil:
        let newProcResult = self.onErrorFn(self)
        if newProcResult.success:
            return newProcResult
    let errData = tail(10, if self.outputErr != "":
            self.outputErr
        else:
            self.output)
    raise newException(ExecError, "\nCommand: " & self.cmd.repr() &
        "\nExitCode: " & $self.exitCode & (if errData == "":
            ""
        else:
            "\n*** COMMAND DATA TAIL ***\n" & errData &
            "\n*** END OF DATA ***\n"
    ))

proc merge*(allResults: varargs[ProcResult]): ProcResult =
    result = ProcResult()
    var length: int
    
    length = allResults.len() - 1 # separator
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

proc setOnErrorFn(self: ProcResult, onErrorFn: OnErrorFn) =
    self.onErrorFn = onErrorFn
