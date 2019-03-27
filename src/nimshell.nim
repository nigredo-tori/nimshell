{.push warnings:off hints:off.}
import os, osproc, macros, parseutils, sequtils, streams, strutils, options, oids
{.pop.}

import ./nimshell/private/utils

type
  Command* = ref object
    value: string
    process: Option[Process]
    stdout: Option[Stream]

proc newCommand*(cmd: string): Command =
  new(result)
  result.value = cmd
  result.process = none(Process)
  result.stdout = none(Stream)

proc close*(cmd: Command) =
  map(cmd.process, close)

var
  lastExitCode {.threadvar.}: int

proc `>>?`*(c: Command): int

proc exitCode*(c: Command): int =
  if isNone(c.process):
    lastExitCode = >>? c
  else:
    lastExitCode = waitForExit(c.process.get())
  result = lastExitCode

proc `$?`*(): int = lastExitCode

macro cmd*(text: string{lit}): Command =
  var nodes: seq[NimNode] = @[]
  for k, v in text.strVal.interpolatedFragments:
    if k == ikStr or k == ikDollar:
      nodes.add(newLit(v))
    else:
      nodes.add(parseExpr("$(" & v & ")"))
  var str = newNimNode(nnkStmtList).add(
    foldr(nodes, a.infix("&", b)))
  result = newCall(bindSym"newCommand", str)

when not defined(shellNoImplicits):
  converter stringToCommand*(s: string): Command = newCommand(s)
  converter commandToBool*(c: Command): bool = c.exitCode() == 0

proc `&>`*(c: Command, s: Stream): Command =
  assert isNone(c.process)
  c.stdout = some(s)
  result = c

proc execCommand*(c: Command, options: set[ProcessOption] = {}) =
  assert isNone(c.process)
  var opt = options
  var line = c.value
  if isNone(c.stdout):
    opt = opt + {poParentStreams}
  when defined(windows):
    line = "cmd /q /d /c " & line
  c.process = some(startProcess(line, "", [], nil, opt + {poEvalCommand, poUsePath, poStdErrToStdOut}))
  if isSome(c.stdout):
    c.process.get().outputStream().copyStream(c.stdout.get())

proc `>>?`*(c: Command): int =
  if isNone(c.process):
    execCommand(c)
  result = c.exitCode()

proc `>>`*(c: Command) =
  discard >>? c

proc `>>!`*(c: Command) =
  let res = >>? c
  if res != 0:
    write(stderr, "Error code " & $res & " while executing command: " & c.value & "\n")
    quit(res)

proc devNull*(): Stream {.inline.} = newDevNullStream()

template SCRIPTDIR*: string =
  parentDir(instantiationInfo(0, true).filename)

proc `$`*(c: Command): string =
  let sout = newStringStream()
  >> (c &> sout)
  result = sout.data.strip

proc `$$`*(c: Command): seq[string] =
  result = ($c).splitLines()
  if result[0] == "":
    result = @[]

####################################################################################################
# Helpers

proc mktemp*(): string =
  result = getTempDir() / $genOid()
  createDir(result)

proc `?`*(s: string): bool = not (s.strip == "")

proc findInPath(name: string): string =
  if existsFile name:
    return name
  for p in getEnv("PATH").split(PathSep):
    if existsFile(p / name):
      return (p / name)
  return ""

when defined(windows):
  proc which*(name: string): string =
    result = findInPath name
    if not ?result:
      result = findInPath(name & ".exe")

  proc sh*(name: string): string = name & ".bat"
  proc exe*(name: string): string = name & ".exe"
  
elif defined(posix):
  proc which*(name: string): string = findInPath name

  proc sh*(name: string): string = name & ".sh"
  proc exe*(name: string): string = name
