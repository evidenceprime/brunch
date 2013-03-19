'use strict'

debug = require('debug')('brunch:generated-file')
fs = require 'fs'
inflection = require 'inflection'
sysPath = require 'path'
async = require 'async'
common = require './common'

cachedTestFiles = null

findTestFiles = (config) ->
  cachedTestFiles ?= getTestFiles config

sortAlphabetically = (a, b) ->
  if a < b
    -1
  else if a > b
    1
  else
    0

# If item path starts with 'vendor', it has bigger priority.
sortByVendor = (config, a, b) ->
  aIsVendor = config.vendorConvention a
  bIsVendor = config.vendorConvention b
  if aIsVendor and not bIsVendor
    -1
  else if not aIsVendor and bIsVendor
    1
  else
    # All conditions were false, we don't care about order of
    # these two items.
    sortAlphabetically a, b

# Items wasn't found in config.before, try to find then in
# config.after.
# Item that config.after contains would have lower sorting index.
sortByAfter = (config, a, b) ->
  indexOfA = config.after.indexOf a
  indexOfB = config.after.indexOf b
  [hasA, hasB] = [(indexOfA isnt -1), (indexOfB isnt -1)]
  if hasA and not hasB
    1
  else if not hasA and hasB
    -1
  else if hasA and hasB
    indexOfA - indexOfB
  else
    sortByVendor config, a, b

# Try to find items in config.before.
# Item that config.after contains would have bigger sorting index.
sortByBefore = (config, a, b) ->
  indexOfA = config.before.indexOf a
  indexOfB = config.before.indexOf b
  [hasA, hasB] = [(indexOfA isnt -1), (indexOfB isnt -1)]
  if hasA and not hasB
    -1
  else if not hasA and hasB
    1
  else if hasA and hasB
    indexOfA - indexOfB
  else
    sortByAfter config, a, b

# Sorts by pattern.
#
# Examples
#
#   sort ['b.coffee', 'c.coffee', 'a.coffee'],
#     before: ['a.coffee'], after: ['b.coffee']
#   # => ['a.coffee', 'c.coffee', 'b.coffee']
#
# Returns new sorted array.
sortByConfig = (files, config) ->
  if toString.call(config) is '[object Object]'
    cfg =
      before: config.before ? []
      after: config.after ? []
      vendorConvention: (config.vendorConvention ? -> no)
    files.slice().sort (a, b) -> sortByBefore cfg, a, b
  else
    files

flatten = (array) ->
  array.reduce (acc, elem) ->
    acc.concat(if Array.isArray(elem) then flatten(elem) else [elem])
  , []

extractOrder = (files, config) ->
  types = files.map (file) -> inflection.pluralize file.type
  orders = Object.keys(config.files)
    .filter (key) ->
      key in types
    .map (key) ->
      config.files[key].order ? {}

  before = flatten orders.map (type) -> (type.before ? [])
  after = flatten orders.map (type) -> (type.after ? [])
  vendorConvention = config._normalized.conventions.vendor
  {before, after, vendorConvention}

sort = (files, config) ->
  paths = files.map (file) -> file.path
  indexes = Object.create(null)
  files.forEach (file, index) -> indexes[file.path] = file
  order = extractOrder files, config
  sortByConfig(paths, order).map (path) ->
    indexes[path]

loadTestFiles = (files, testsConvention) ->
  files
    .map (file) ->
      file.path
    .filter (path) ->
      testsConvention path
    .map (path) ->
      path = path.replace RegExp('\\\\', 'g'), '/'
      path.substring 0, path.lastIndexOf '.'
    .map (path) ->
      "window.require('#{path}');"
    .join('\n') + '\n'

# File which is generated by brunch from other files.
module.exports = class GeneratedFile
  #
  # path        - path to file that will be generated.
  # sourceFiles - array of `fs_utils.SourceFile`-s.
  # config      - parsed application config.
  #
  constructor: (@path, @sourceFiles, @config, minifiers) ->
    @type = if @sourceFiles.some((file) -> file.type is 'javascript')
      'javascript'
    else
      'stylesheet'
    @minifier = minifiers.filter((minifier) => minifier.type is @type)[0]
    @isTestFile = @path in findTestFiles @config
    Object.freeze this

  # Private: Collect content from a list of files and wrap it with
  # require.js module definition if needed.
  # Returns string.
  _join: (files, callback) ->
    debug "Joining files '#{files.map((file) -> file.path).join(', ')}'
 to '#{@path}'"
    requireFiles = => loadTestFiles files, @config._normalized.conventions.tests
    joined = files.map((file) -> file.cache.data).join('')
    process.nextTick =>
      if @type is 'javascript'
        data = @config._normalized.modules.definition(@path, joined) + joined
        callback null, (if @isTestFile then data + requireFiles() else data)
      else
        callback null, joined

  # Private: minify data.
  #
  # data     - string of js / css that will be minified.
  # callback - function that would be executed with (minifyError, data).
  #
  # Returns nothing.
  _minify: (data, callback) ->
    if @config.optimize
      minify = @minifier?.optimize ? @minifier?.minify
      minify? data, @path, callback
    else
      callback null, data

  # Joins data from source files, minifies it and writes result to
  # path of current generated file.
  #
  # callback - minify / write error or data of written file.
  #
  # Returns nothing.
  write: (callback) ->
    @_join (sort @sourceFiles, @config), (error, joined) =>
      return callback error if error?
      @_minify joined, (error, data) =>
        return callback error if error?
        common.writeFile @path, data, callback
