import asyncproc
import asyncio/asyncstream
import std/[os, sequtils, envvars, strutils]

import std/unittest

var sh = ProcArgs(options: { QuoteArgs, CaptureOutput, CaptureOutputErr, NoParentEnv })
var shWithPrefix = ProcArgs(prefixCmd: @["sh", "-c"], options: { QuoteArgs, CaptureOutput, CaptureOutputErr })
var shUnquotedWithPrefix = ProcArgs(prefixCmd: @["sh", "-c"], options: { CaptureOutput, CaptureOutputErr })
var shMergedStderr = shUnquotedWithPrefix.merge(toAdd = { MergeStderr })

let pid = getCurrentProcessId()
proc getFdCount(): int =
    toSeq(walkDir("/proc/" & $pid & "/fd", relative=true)).len()

proc main() {.async.} =
    test "Basic IO":
        check (await sh.runCheck(@["true"]))
        check not (await sh.runCheck(@["false"]))
        check (await sh.runGetOutput(@["echo", "Hello"])) == "Hello"
        check (await sh.runGetOutput(@["echo", "-n", "Hello"])) == "Hello"
        check (await sh.runGetLines(@["echo", "line1\nline2"])) == @["line1", "line2"]
        check getFdCount() == 5

    test "workingDir":
        let workingDir = "/home"
        check (await sh.runGetOutput(@["pwd"], ProcArgsModifier(workingDir: some workingDir))) == workingDir
        check getFdCount() == 5

    test "logFn":
        var loggedVal: string
        discard await sh.run(@["echo", "Hello"], ProcArgsModifier(
            toAdd: { CaptureOutput, WithLogging },
            logFn: some proc(res: ProcResult) =
                loggedVal = withoutLineEnd res.output
        ))
        check loggedVal == "Hello"
        check getFdCount() == 5

    test "No Output":
        var shNoOutput = ProcArgs(options: { QuoteArgs })
        check not (await shNoOutput.run(@["echo", "Hello"])).success
        check getFdCount() == 5

    test "With Tee output":
        var outStream = AsyncStream.new()
        check (await sh.runGetOutput(@["echo", "Hello"], ProcArgsModifier(output: some outStream.writer.AsyncIoBase))) == "Hello"
        check (await outStream.readAll()) == "Hello\n"
        check getFdCount() == 5

    test "implicit await":
        var sh2 = sh.deepCopy()
        implicitAwait(@["sh2"]):
            check sh2.runGetOutput(@["echo", "Hello"]) == "Hello"
            check (await sh.runGetOutput(@["echo", "Hello"])) == "Hello"
        check getFdCount() == 5

    test "environment":
        var shWithParentEnv = sh.deepCopy().merge(toRemove = { NoParentEnv })
        check (await sh.runGetOutput(@["env"])) == ""
        check (await sh.runGetOutput(@["env"], ProcArgsModifier(env: some {"VAR": "VALUE"}.toTable))) == "VAR=VALUE"
        putEnv("KEY", "VALUE")
        check "KEY=VALUE" in (await shWithParentEnv.runGetLines(@["env"]))
        check getFdCount() == 5

    test "with interpreter: Quoted":
        check (await shWithPrefix.runGetOutput(@["echo", "Hello"])) == "Hello"
        check not (await shWithPrefix.run(@["echo Hello"])).success
        check getFdCount() == 5

    test "with interpreter: Unquoted":
        check (await shUnquotedWithPrefix.runGetOutput(@["echo", "Hello"])) == "Hello"
        check (await shUnquotedWithPrefix.runGetOutput(@["echo Hello"])) == "Hello"
        check getFdCount() == 5

    test "Stderr":
        check (await shUnquotedWithPrefix.run(@["echo Hello >&2"])).output == ""
        check (await shUnquotedWithPrefix.run(@["echo Hello >&2"])).outputErr == "Hello\n"
        check (await shUnquotedWithPrefix.merge(toRemove = {CaptureOutputErr}).run(@["echo Hello >&2"])).outputErr == ""
        check (await shMergedStderr.run(@["echo Hello"])).output == "Hello\n"
        check (await shMergedStderr.run(@["echo Hello >&2"])).output == "Hello\n"
        check (await shMergedStderr.run(@["echo Hello >&2"])).outputErr == ""        
        check getFdCount() == 5

    test "EnvOnComdline: Quoted":
        # sh add a few env variable
        check "VAR=VALUE" in (await shWithPrefix.runGetLines(@["env"], ProcArgsModifier(
            env: some {"VAR": "VALUE"}.toTable,
            toAdd: { SetEnvOnCmdLine }
        )))
        # Side effect, because quoted, space is well captured
        check "VAR=VALUE SPACED" in (await shWithPrefix.runGetLines(@["env"], ProcArgsModifier(
            env: some {"VAR": "VALUE SPACED"}.toTable,
            toAdd: { SetEnvOnCmdLine }
        )))
        check getFdCount() == 5
        
    test "EnvOnComdline: Unquoted":
        # sh add a few env variable
        check "VAR=VALUE" in (await shUnquotedWithPrefix.runGetLines(@["env"], ProcArgsModifier(
            env: some {"VAR": "VALUE"}.toTable,
            toAdd: { SetEnvOnCmdLine }
        )))
        # >>> @["sh", "-c", "export VAR=VALUE SPACED; env"]
        check "VAR=VALUE SPACED" notin (await shUnquotedWithPrefix.runGetLines(@["env"], ProcArgsModifier(
            env: some {"VAR": "VALUE SPACED"}.toTable,
            toAdd: { SetEnvOnCmdLine }
        )))
        check getFdCount() == 5

    test "Interactive with input capture":
        var sh2 = ProcArgs(prefixCmd: @["sh", "-c"], options: { Interactive, CaptureInput, CaptureOutput, CaptureOutputErr })
        var sh2Merged = sh2.merge(toAdd = { MergeStderr })

        var outputStr = (await sh2Merged.run(@["echo Hello"])).output
        check outputStr == "Hello\r\n"
        check outputStr.withoutLineEnd() == "Hello"
        check (await sh2.run(@["echo Hello"])).output == "Hello\n"
        discard await stdoutAsync.write "Please provide an input: "
        var procRes = await sh2.run(@["read a; echo $a"])
        check procRes.input == procRes.output
        check getFdCount() == 5
    

waitFor main()