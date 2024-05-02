import std/[tables, envvars]
from std/os import quoteShell

export quoteShell, tables

type
    ProcEnv* = Table[string, string]
        ## Interface to set up subprocess env
        ## Not used to modify terminal env


proc newEmptyEnv*(): ProcEnv
proc newEnvFromParent*(): ProcEnv

# In other modules:
proc mergeEnv(first, second: ProcEnv): ProcEnv {.used.}
proc toShellFormat(env: ProcEnv, quoteArgs: bool): string  {.used.}


converter toEnv*(table: Table[string, string]): ProcEnv =
    ProcEnv(table)

proc newEmptyEnv*(): ProcEnv =
    discard

proc newEnvFromParent*(): ProcEnv =
    ## Create an env object filled with parent environment
    ## Can make a the command pretty long if used with SetEnvOnCmdLine flag, but should not cause issue
    for k, v in envPairs():
        result[k] = v

proc mergeEnv(first, second: ProcEnv): ProcEnv =
    ## Second will overwrite first
    if second.len() == 0:
        return first
    if first.len() == 0:
        return second
    for k, v in second.pairs():
        result[k] = v

proc toShellFormat(env: ProcEnv, quoteArgs: bool): string =
    var exportCmd: string
    if quoteArgs:
        for (key, val) in env.pairs():
            exportCmd.add " " & quoteShell(key) & "=" & quoteShell(val)
    else:
        for (key, val) in env.pairs():
            exportCmd.add " " & key & "=" & val
    if exportCmd != "":
        return "export" & exportCmd & "; "