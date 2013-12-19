{spawn, exec} = require 'child_process'
fs = require 'fs'
log = console.log

task 'build', ->
  fs.mkdir('lib', 0o0755) unless fs.exists 'lib'
  run 'coffee -o lib -c src/*.coffee'

task 'test', ->
  run 'cd test; coffee templateTests.coffee'

task 'clean', ->
  run 'npm remove -g coffin'

task 'install', ->
  invoke 'build'
  run 'npm install -g .'

task 'all', ->
  invoke 'clean'
  invoke 'test'
  invoke 'build'
  invoke 'install'

run = (args...) ->
  for a in args
    switch typeof a
      when 'string' then command = a
      when 'object'
        if a instanceof Array then params = a
        else options = a
      when 'function' then callback = a

  command += ' ' + params.join ' ' if params?
  cmd = spawn '/bin/sh', ['-c', command], options
  cmd.stdout.on 'data', (data) -> process.stdout.write data
  cmd.stderr.on 'data', (data) -> process.stderr.write data
  process.on 'SIGHUP', -> cmd.kill()
  cmd.on 'exit', (code) -> callback() if callback? and code is 0
