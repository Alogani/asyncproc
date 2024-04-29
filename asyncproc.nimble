# Package

version       = "0.3.0"
author        = "alogani"
description   = "Flexible child process spawner with strong async features"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.0.2"
requires "aloganimisc >= 0.1.1"
requires "asyncio >= 0.4.0"

task reinstall, "Reinstalls this package":
    var path = "~/.nimble/pkgs2/" & projectName() & "-" & $version & "-*"
    exec("rm -rf " & path)
    exec("nimble install")
