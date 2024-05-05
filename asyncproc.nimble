# Package

version       = "0.4.0"
author        = "alogani"
description   = "Flexible child process spawner with strong async features"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.0.2"
requires "aloganimisc ~= 0.1.1"
requires "asyncio ~= 0.6.0"
requires "asyncsync ~= 0.4.0"

task reinstall, "Reinstalls this package":
    var path = "~/.nimble/pkgs2/" & projectName() & "-*"
    exec("rm -rf " & path)
    exec("nimble install")

task genDocs, "Build the docs":
    ## importBuilder source code: https://github.com/Alogani/shellcmd-examples/blob/main/src/importbuilder.nim
    let githubUrl = "https://github.com/Alogani/asyncio"
    let bundlePath = "htmldocs/" & projectName() & ".nim"
    exec("./htmldocs/importbuilder --build src " & bundlePath & " --discardExports")
    exec("nim doc --git.url:" & githubUrl & " --git.commit:v" & $version & " --project --index:on --outdir:htmldocs " & bundlePath)

task genDocsAndPush, "genDocs -> git push":
    genDocsTask()
    exec("git add htmldocs")
    exec("git commit -m 'Update docs'")
    exec("git push")
