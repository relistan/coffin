fs             = require 'fs'
path           = require 'path'
colors         = require 'colors'
commander      = require 'commander'
CoffeeScript   = require 'coffee-script'
{spawn, exec}  = require 'child_process'
parseTemplate  = require './parseTemplate'
commandHelper  = require './commandHelper'
coffinChar     = '\u26B0'.grey
checkChar      = '\u2713'.green
crossChar      = '\u2717'.red

validateArgs = ->
  valid = true
  if commander.args.length is 0
    console.error "You need to specify a coffin template to act on."
    valid = false
  if commander.validate? or commander.createStack? or commander.updateStack?
    if commander.print?
      console.error "I can't run that command if you're just printing to the console."
      valid = false
    if not process.env.AWS_CLOUDFORMATION_HOME and not commander['cfn-home']?
      console.error "Either an AWS_CLOUDFORMATION_HOME environment variable or a --cfnHome switch is required."
      valid = false
  if not valid
    process.stdout.write commander.helpInformation()
    process.exit 1

compileTemplate = (source, callback) =>
  pre = "require('../lib/coffin') ->\n"

  unless fs.exists(source)
    process.stdout.write('You must provide a filename to compile!')
    process.exit 2

  fs.readFile source, (err, code) =>
    if err
      console.error "#{source} not found"
      process.exit 1
    tabbedLines = []
    (tabbedLines.push('  ' + line) for line in code.toString().split '\n')
    tabbedLines.push '  return'
    code = tabbedLines.join '\n'
    code = pre + code
    compiled = CoffeeScript.compile code, {source, bare: false}
    template = eval compiled, source
    templateString = if commander.pretty then JSON.stringify template, null, 2 else JSON.stringify template
    callback? templateString

decompileCfnTemplate = (source, callback) ->
  fs.readFile source, "utf8", (err, cfnTemp) ->
    if err
      console.log "#{source} not found"
      process.exit 1
    decompiled = parseTemplate JSON.parse(cfnTemp)
    callback decompiled

writeJsonTemplate = (json, templatePath, callback) ->
  write = ->
    json = ' ' if json.length <= 0
    fs.writeFile templatePath, json, (err) ->
      if err?
        console.error "failed to write to #{templatePath}"
        console.error err.message
        process.exit 1
      callback?()
  base = path.dirname templatePath
  fs.exists base, (exists) ->
    if exists then write() else exec "mkdir -p #{base}", write

generateTempFileName = ->
  e = process.env
  tmpDir = e.TMPDIR || e.TMP || e.TEMP || '/tmp'
  now = new Date()
  dateStamp = now.getYear()
  dateStamp <<= 4
  dateStamp |= now.getMonth()
  dateStamp <<= 5
  dateStamp |= now.getDay()
  rand = (Math.random() * 0x100000000 + 1).toString(36)
  name = "#{dateStamp.toString(36)}-#{process.pid.toString(36)}-#{rand}.template"
  path.join tmpDir, name

generateOutputFileName = (source, extension) ->
  base = commander.output || path.dirname source
  filename  = path.basename(source, path.extname(source)) + extension
  path.join base, filename

buildCfnPath = ->
  cfnHome = commander['cfn-home'] || process.env.AWS_CLOUDFORMATION_HOME
  return path.normalize path.join cfnHome, 'bin'

validateTemplate = (templatePath, callback) =>
  validateExec = spawn path.join(buildCfnPath(), 'cfn-validate-template'), ['--template-file', templatePath]
  errorText = ''
  resultText = ''
  validateExec.stderr.on 'data', (data) -> errorText += data.toString()
  validateExec.stdout.on 'data', (data) -> resultText += data.toString()
  validateExec.on 'exit', (code) ->
    if code is 0
      process.stdout.write "#{checkChar}\n"
      process.stdout.write resultText
    else
      process.stdout.write "#{crossChar}\n"
      process.stderr.write errorText
    callback?(code)

updateOrCreateStack = (name, templatePath, compiled, callback) =>
  args = ['--template-file', templatePath, '--stack-name', name]
  if commandHelper.doesTemplateReferenceIAM compiled
    args.push '-c'
    args.push 'CAPABILITY_IAM'
  if commander.parameters?
    args.push '--parameters'
    args.push commander.parameters
  updateExec = spawn "#{buildCfnPath()}/cfn-update-stack", args
  updateErrorText = ''
  resultText = ''
  updateExec.stderr.on 'data', (data) -> updateErrorText += data.toString()
  updateExec.stdout.on 'data', (data) -> resultText += data.toString()
  updateExec.on 'exit', (code) ->
    existsSyncFunc = if fs.existsSync? then fs.existsSync
    if existsSyncFunc "#{buildCfnPath()}/cfn-update-stack"
      if code is 0
        process.stdout.write "stack '#{name}' (updated) #{checkChar}\n"
        process.stdout.write resultText
        callback? code
        return
      if updateErrorText.match(/^cfn-update-stack:  Malformed input-No updates are to be performed/)?
        process.stdout.write "stack '#{name}' (no changes)\n"
        process.stdout.write resultText
        callback? 0
        return
      if not updateErrorText.match(/^cfn-update-stack:  Malformed input-Stack with ID\/name/)?
        console.error updateErrorText
        callback? code
        return
    createStack name, templatePath, compiled, callback

createStack = (name, templatePath, compiled, callback) =>
  args = ['--template-file', templatePath, '--stack-name', name]
  if commandHelper.doesTemplateReferenceIAM compiled
    args.push '-c'
    args.push 'CAPABILITY_IAM'
  if commander.parameters?
    args.push '--parameters'
    args.push commander.parameters
  createExec = spawn "#{buildCfnPath()}/cfn-create-stack", args
  errorText = ''
  resultText = ''
  createExec.stdout.on 'data', (data) -> resultText += data.toString()
  createExec.stderr.on 'data', (data) -> errorText += data.toString()
  createExec.on 'exit', (code) ->
    if code isnt 0
      if errorText.match(/^cfn-create-stack:  Malformed input-AlreadyExistsException/)?
        process.stderr.write "stack '#{name}' already exists #{crossChar}\n"
        return
      process.stderr.write errorText
      return
    process.stdout.write "stack '#{name}' (created) #{checkChar}\n"
    process.stdout.write resultText
    callback? code


pretty =
  switch: '-p, --pretty'
  text:   'Add spaces and newlines to the resulting json to make it a little prettier'

commander.version require('./coffin').version
commander.usage '[options] <coffin template>'

commander.option '-o, --output [dir]', 'Directory to output compiled file(s) to'
commander.option '--cfn-home [dir]', 'The home of your AWS Cloudformation tools. Defaults to your AWS_CLOUDFORMATION_HOME environment variable.'
commander.option pretty.switch, pretty.text
commander.option '-P, --parameters [dir]', "Parameters to overide Parameter defaults."

printCommand = commander.command 'print [template]'
printCommand.description 'Print the compiled template.'
printCommand.action (template) ->
  validateArgs()
  compileTemplate template, (compiled) ->
    console.log compiled

validateCommand = commander.command 'validate [template]'
validateCommand.description 'Validate the compiled template. Either an AWS_CLOUDFORMATION_HOME environment variable or a --cfn-home switch is required.'
validateCommand.action (template) ->
  validateArgs()
  compileTemplate template, (compiled) ->
    process.stdout.write "#{coffinChar} #{template} "
    tempFileName = generateTempFileName()
    writeJsonTemplate compiled, tempFileName, ->
      validateTemplate tempFileName, (resultCode) ->

stackCommand = commander.command 'stack [name] [template]'
stackCommand.description 'Create or update the named stack using the compiled template. Either an AWS_CLOUDFORMATION_HOME environment variable or a --cfn-home switch is required.'
stackCommand.action (name, template) ->
  validateArgs()
  compileTemplate template, (compiled) ->
    tempFileName = generateTempFileName()
    writeJsonTemplate compiled, tempFileName, ->
      process.stdout.write "#{coffinChar} #{template} -> "
      updateOrCreateStack name, tempFileName, compiled, (resultCode) ->

compileCommand = commander.command 'compile [template]'
compileCommand.description 'Compile and write the template. The output file will have the same name as the coffin template plus a shiny new ".template" extension.'
compileCommand.action (template) ->
  validateArgs()
  compileTemplate template, (compiled) ->
    process.stdout.write "#{coffinChar} #{template} -> "
    fileName = generateOutputFileName template, ".template"
    writeJsonTemplate compiled, fileName, ->
      process.stdout.write "#{fileName}\n"

decompileCommand = commander.command 'decompile [cfn-template]'
decompileCommand.description 'experimental - Convert the given cloud formation template to coffin (or as best as we can). It will output a file of the same name with ".coffin" extension.'
decompileCommand.action (cfnTemplate) ->
  validateArgs()
  decompileCfnTemplate cfnTemplate, (decompiled) ->
    process.stdout.write "#{coffinChar} #{cfnTemplate} -> "
    fileName = generateOutputFileName cfnTemplate, ".coffin"
    writeJsonTemplate decompiled, fileName, ->
      process.stdout.write "#{fileName}\n"



showHelp = ->
  process.stdout.write commander.helpInformation()
  process.exit 1
commander.command('').action showHelp
commander.command('*').action showHelp

if process.argv.length <=2
  showHelp()

module.exports.run = ->
  commander.parse process.argv
