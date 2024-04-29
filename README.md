# Asyncproc

Asynchronous child process spawner, with high flexibility on its stream handling for input/output/erro handles.
It was specially built to close the gap from shell language and nim.

## Features

- Developped with interactivness in mind (you can easily mixed user input/output, and automated input)
- Concise: even complex configurations can be one-lined (see also implicitAsync macro to avoid repetition of await keyword)
- Flexible and straightforward. All options can be tweaked using a flag :
  - Can be easily put in true foreground, keeping the ability to terminal process control (ctrl+c, ctrl+z in linux) and to have shell history
  - Can capture input/output/output error streams, even when put on foreground
  - Can separate error stream or keep it merged with preserving writing order
  - Have other facilities to help logging, printing what is done, managing process environment, making deamons (command surviving its parent), etc.
- Powerful streams manipulation thanks to [asyncio](https://github.com/Alogani/asyncio) library

## Getting started

### Installation

`nimble install asyncproc`

### Example usage (linux)

```
import std/options
import asyncproc

const myFile = "myfile.txt"

proc main() {.async.} =
  ## Create a file
  await sh.runAssertDiscard(@["touch", myFile])

  ## Check the file has been created
  echo true == (await sh.runCheck(@["test", "-f", myFile]))

  ## List its content
  echo await sh.runGetOutput(@["cat", myFile])

  ## List all files in current directory
  echo await sh.runGetLines(@["ls"])

  ## Write to the file
  await sh.runAssertDiscard(@["dd", "of=" & myFile], ProcArgsModifier(input = some AsyncString.new("Hello world")))

waitFor main()
```

#### To go further

Please see [tests](https://github.com/Alogani/asyncproc/tree/main/tests) to see more usages.

You can also see [shellcmd](https://github.com/Alogani/shellcmd) source code to view what you can do and how with asyncproc api

## Before using it

- **Unstable API** : How you use asyncproc is susceptible to change. It could occur to serve [shellcmd](https://github.com/Alogani/shellcmd) library development. If you want to use as a pre-release, please only install and use a tagged version and don't update frequently until v1.0.0 is reached. Releases with breaking change will make the second number of semver be updated (eg: v0.1.1 to v0.2.0)
- Only available in unix. Support for windows is not in the priority list
- Only support one async backend: std/asyncdispatch (incompatible with chronos)
- Don't expect more performance. Although development is focused to avoid unecessary or costly operations, asynchronous code has a large overhead and is usually far slower than sync one in many situations. Furthermore concisness and flexibilty are proritized
