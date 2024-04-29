import std/options
import asyncproc
import asyncio/asyncstring

const myFile = "myfile.txt"

proc main() {.async.} =
  ## Create a file
  await sh.runDiscard(@["touch", myFile])

  ## Check the file has been created
  echo true == (await sh.runCheck(@["test", "-f", myFile]))

  ## List its content
  echo await sh.runGetOutput(@["cat", myFile])

  ## List all files in current directory
  echo await sh.runGetLines(@["ls"])

  ## Write to the file
  await sh.runDiscard(@["dd", "of=" & myFile], input = some AsyncString.new("Hello world\n").AsyncIoBase, toRemove = { Interactive })

waitFor main()