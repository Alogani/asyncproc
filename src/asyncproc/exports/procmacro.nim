import std/[macros, asyncdispatch]
import ./procargsresult

#[
    TODO: 
        - test if it behaves correctly :
            implicitAsync(@["sh"]):
                sh.mergeArgs(blah).run()
                sh.runGetLine().output
        - provide a way to register line info for debugging purpose:
            getLineContent() -> give it to sh
]#

macro tryOrFallBack*(cmd: untyped, body: untyped) =
    ## Command is only valid if await(`cmd`).exitCode is valid
    ## Can be good to encapsulate multiple statements, but OnErrorFn is more reliable
    let bodyrepr = body.repr
    quote do:
        while true:
            try:
                `body`
                break
            except Exception as err:
                echo "\nAn error occured while executing:", `bodyrepr`, "\n"
                echo getStackTrace()
                echo "FALLBACK TO SHELL, ExitCode meaning: 0 == retry, 1 == quit, 125 == skip"
                let procRes = `cmd`
                let exitCode = when procRes is Future[ProcResult]:
                        await(procRes).exitCode
                    else:
                        procRes.exitCode
                if exitCode == 125:
                    break
                elif exitCode != 0:
                    raise err

proc implicitAwaitHelper(identNames: seq[string], node: NimNode): NimNode =
    var nodeCopy = node.copyNimNode()
    if node.kind in [nnkCall, nnkCommand] and node[0].kind == nnkDotExpr:
        if node[0][0].kind in [nnkCall, nnkCommand] and
                node[0][0][0].kind == nnkDotExpr and
                node[0][0][0][0].strVal in identNames:
            nodeCopy.add node[0].copyNimTree()
            for child in node[1..^1]:
                nodeCopy.add implicitAwaitHelper(identNames, child)
            return newCall("await", nodeCopy)
        if node[0][0].kind == nnkIdent and node[0][0].strVal in identNames:
            for child in node:
                nodeCopy.add implicitAwaitHelper(identNames, child)
            return newCall("await", nodeCopy)
    for child in node:
        nodeCopy.add implicitAwaitHelper(identNames, child)
    return nodeCopy

macro implicitAwait*(identNames: static[seq[string]], body: untyped): untyped =
    #[  Replace only on method call syntax
        To escape : use procedural call syntax or put ident name inside parenthesis
        Can understand only one merge eg: sh.merge(...).run(...), but no await is implictly put inside merge
        If put inside async function, will be called twice...
    ]#
    result = implicitAwaitHelper(identNames, body)
