--[[
This is a library to make custom binary data file formats incredibly easy to develop.
To get started, you'll need to create a new struct.

local bfile = require("bfile")
local myStruct = bfile.newStruct("myStruct")

Now this alone isn't much help, you've created an empty struct. Time to add some data!

myStruct:constant("myStruct"):add("uint8", "myValue")

Here we add two elements to our struct, first a constant.
This constant will write the string literal "myStruct" to the file,
this literal will also be loaded back and asserted to match when loading.

The second element we added is data. We specifically added an 8 bit unsigned integer.
Look at structReaders and structWriters to see supported primative data types.
The string passed in ("myValue") is the index into the table we want to write/load.
If we want to write this struct to a file now we should do something like the following.

myStruct:writeFile("myStructFile.bin", {myValue=100})

As you can see, the uint8 we are writing is at the index "myValue". 
You can use any type here (that can be used to index tables).

Now this alone is a little usable, but what happens when you wanna store an array of objects?
Well, you can do that too!

local newStruct = bfile.newStruct("newStruct"):add("myStruct[]", "myStructs")

Simply by adding [] to the end of the type name you can convert it into an array.
There's some special syntax here, specifically there's 4 usages of this:
* [] - write the length of the table using the defaultArrayLength type
* [*] - the array runs out the length of the file. This HAS to be the last type in a struct if you use it.
* [12] - use a literal integer for the length of the array, this doesn't get written to disk, so you have to know it to read it back.
* [uint8] - use an integer type name to specify what type to use to write the array length.

If you didn't notice above you can use structs in structs. The struct will be loaded as a table at the key you give.

One more thing, if you want a map of one type to another type, of any size, there's a syntax for that too.

newStruct:add("map<string,myStruct[]>", "lotsOfStructs")

There's no additional rules to that other than map<keytype,valuetype>. Yes you can have an array of maps. Multidimensional arrays also work.

If you need to unpack a type table so it's in the parent table, set the key to "^".
]]

---Create a rudamentary emulator of a file handle from a string.
---@return handle
local function stringHandle(str)
  local pointer = 0

  local function limitPointer(modifier)
    pointer = math.max(0,math.min(pointer + (modifier or 0), str:len()))
    return pointer
  end

  local handle = {}

  function handle.read(count)
    local start = pointer+1
    local finish = limitPointer(count or 1)
    local retStr = str:sub(start,finish)
    if start-1 == finish then
      -- end of string
      return
    end
    if count then
      return retStr
    else
      return retStr:byte()
    end
  end

  function handle.seek(whence, offset)
    whence = whence or "cur"
    offset = offset or 0
    if whence == "cur" then
      pointer = pointer + offset
    elseif whence == "set" then
      pointer = offset
    elseif whence == "end" then
      pointer = str:len() - 1 + offset
    else
      error("Invalid whence option")
    end
    limitPointer()
    return pointer
  end

  function handle.write(value)
    if type(value) == "number" then
      value = string.char(value)
    end
    local start = pointer+1
    pointer = pointer + value:len()
    str = str:sub(1,start-1) .. value .. str:sub(pointer+1)
  end

  function handle.getString()
    return str
  end

  return handle
end

local structReaders = {
  uint8 = function (f)
    return select(1,string.unpack("I1",f.read(1)))
  end,
  uint16 = function (f)
    return select(1,string.unpack(">I2",f.read(2)))
  end,
  string = function (f)
    local length = string.unpack(">I2", f.read(2))
    local str = f.read(length)
    return str
  end,
  char = function (f)
    return f.read(1)
  end,
  uint32 = function (f)
    return select(1, string.unpack(">I4",f.read(4)))
  end,
  number = function (f)
    return select(1, string.unpack("n", f.read(8)))
  end
}

local structWriters = {
  uint8 = function (f,value)
    f.write(string.pack("I1", value))
  end,
  uint16 = function (f,value)
    f.write(string.pack(">I2", value))
  end,
  string = function (f,value)
    f.write(string.pack(">I2", value:len()))
    f.write(value)
  end,
  char = function (f,value)
    f.write(value)
  end,
  uint32 = function (f,value)
    f.write(string.pack(">I4", value))
  end,
  number = function (f, value)
    f.write(string.pack("n", value))
  end
}

local defaultArrayLength = "uint32"

local getReaderWriter

---@type table<string,table>
local structs = {}

local function arrayReaderGen(arrayDatatype, lengthDatatype, fixedLength)
  local dataReader = getReaderWriter(arrayDatatype)
  if lengthDatatype == "*" then
    -- read until file runs out
    return function(f)
      local t = {}
      while f.read(1) do
        f.seek(nil, -1)
        t[#t+1] = dataReader(f)
      end
      return t
    end
  end
  if lengthDatatype == "" then
    lengthDatatype = defaultArrayLength
  end
  local lengthReader = getReaderWriter(lengthDatatype)
  return function(f)
    local length
    if fixedLength then
      length = fixedLength
    else
      length = lengthReader(f)
    end
    local t = {}
    for i = 1, length do
      t[i] = dataReader(f)
    end
    return t
  end
end

local function arrayWriterGen(arrayDatatype, lengthDatatype, fixedLength)
  local lengthWriter
  if lengthDatatype == "" then
    _, lengthWriter = getReaderWriter("uint32")
  elseif lengthDatatype ~= "*" then
    _, lengthWriter = getReaderWriter(lengthDatatype)
  end
  local _, dataWriter = getReaderWriter(arrayDatatype)
  return function(f,value)
    if lengthDatatype ~= "*" and not fixedLength then
      -- this has a defined length, without one we can't read it back unless it's the whole file.
      lengthWriter(f,#value)
    end
    for _,v in ipairs(value) do
      dataWriter(f,v)
    end
  end
end

local function mapReaderGen(keyType, valueType)
  local keyReader = getReaderWriter(keyType)
  local valueReader = getReaderWriter(valueType)
  return function(f)
    local t = {}
    while true do
      local key = assert(keyReader(f), "Got nil from reader")
      local value = valueReader(f)
      t[key] = value
      local char = f.read(1)
      if char == ";" then
        return t
      end
      assert(char == ",", "Invalid map separator")
    end
  end
end

local function mapWriterGen(keyType, valueType)
  local _, keyWriter = getReaderWriter(keyType)
  local _, valueWriter = getReaderWriter(valueType)
  return function(f,value)
    local start = true
    for k,v in pairs(value) do
      if not start then
        f.write(",")
      end
      start = false
      keyWriter(f, k)
      valueWriter(f, v)
    end
    f.write(";")
  end
end

---Get a reader and writer for any supported datatype
---@param datatype string
---@generic T : any
---@return fun(f: handle): T
---@return fun(f: handle, v: T)
function getReaderWriter(datatype)
  local reader, writer
  local lengthDatatype = datatype:match("%[([%a%d*]-)%]$")
  local keyType, valueType = datatype:match("^map<([%S]+),([%S]+)>")
  if lengthDatatype then
    local arrayDatatype = datatype:sub(1,-lengthDatatype:len()-3)
    local fixedLength
    if tonumber(lengthDatatype) then
      -- this is a number literal, this array is a fixed size
      fixedLength = tonumber(lengthDatatype)
    end
    reader = arrayReaderGen(arrayDatatype, lengthDatatype, fixedLength)
    writer = arrayWriterGen(arrayDatatype, lengthDatatype, fixedLength)
  elseif keyType then
    reader = mapReaderGen(keyType, valueType)
    writer = mapWriterGen(keyType, valueType)
  elseif structs[datatype] then
    local structDatatype = structs[datatype]
    reader = function(f) return structDatatype:readHandle(f) end
    writer = function(f, value) structDatatype:writeHandle(f, value) end
  else
    reader = structReaders[datatype]
    writer = structWriters[datatype]
  end
  assert(reader, "No reader for "..datatype)
  assert(writer, "No writer for "..datatype)
  return reader, writer
end

---Add a datatype to the struct
---@param self Struct
---@param datatype string
---@param key any
---@return Struct
local function add(self,datatype,key)
  local reader, writer = getReaderWriter(datatype)
  table.insert(self.structure, {
    type = datatype,
    reader = reader,
    writer = writer,
    key = key,
    mode = "data"
  })
  ---@type Struct
  return self
end

---Add a constant to the struct
---These are written directly to the file in this position.
---When read back they are asserted to be the same as written.
---@param self Struct
---@param value string
---@return Struct
local function constant(self, value)
  table.insert(self.structure, {
    mode = "constant",
    value = value,
  })
  return self
end

---Add a conditional to the struct
---Basically, dynamically choose a datatype based on the read character/written data
---@param self any
---@param key any
---@param loadCondition fun(ch: string): string datatype to load
---@param writeCondition fun(value: table): string, string character indicating condition, datatype to save
local function conditional(self,key,loadCondition, writeCondition)
  table.insert(self.structure, {
    mode = "conditional",
    key = key,
    loadCondition = loadCondition,
    writeCondition = writeCondition
  })
end

---Read the struct from the given file handle
---@param self Struct
---@param handle handle
---@return table
local function readHandle(self,handle)
  local t = {}
  for k,v in ipairs(self.structure) do
    if v.mode == "data" then
      t[v.key] = v.reader(handle)
    elseif v.mode == "constant" then
      local readConstant = handle.read(v.value:len())
      assert(readConstant == v.value, ("Constant does not match. Expected %s, got %s."):format(v.value, readConstant))
    elseif v.mode == "conditional" then
      local datatype = v.loadCondition(handle.read(1))
      local reader = getReaderWriter(datatype)
      t[v.key] = reader(handle)
    else
      error("Invalid mode "..v.mode)
    end

    if v.key == "^" then
      -- unpack this table onto the parent table
      for k2,v2 in pairs(t[v.key]) do
        t[k2] = v2
      end
      t[v.key] = nil
    end
  end
  return t
end

---Read the struct from a given file
---@param self Struct
---@param filename string
---@return table|nil
local function readFile(self,filename)
  local f = fs.open(filename, "rb")
  if not f then
    return
  end
  local t = readHandle(self, f)
  f.close()
  return t
end

---Read the struct from a given string
---@param self Struct
---@param str string
---@return table
local function readString(self,str)
  return readHandle(self, stringHandle(str))
end

---Write the struct to a given handle
---@param self Struct
---@param handle handle
---@param t table
local function writeHandle(self,handle,t)
  for k,v in ipairs(self.structure) do
    local valueToWrite = t[v.key]
    if v.key == "^" then
      valueToWrite = t
    end
    assert(valueToWrite, "No value at key="..v.key)
    if v.mode == "data" then
      v.writer(handle,valueToWrite)
    elseif v.mode == "constant" then
      handle.write(v.value)
    elseif v.mode == "conditional" then
      local ch, datatype = v.writeCondition(valueToWrite)
      handle.write(ch)
      local _, writer = getReaderWriter(datatype)
      writer(handle, valueToWrite)
    else
      error("Invalid mode "..v.mode)
    end
  end
end

---Write the struct to a given file
---@param self Struct
---@param filename string
---@param t table
local function writeFile(self,filename,t)
  local f = assert(fs.open(filename, "wb"))
  writeHandle(self, f, t)
  f.close()
end

---Write the struct to a string
---@param self Struct
---@param t table
---@return string
local function writeString(self, t)
  local handle = stringHandle("")
  writeHandle(self, handle, t)
  return handle.getString()
end

---Start creating a struct
---@param name string
---@return Struct
local function newStruct(name)
  ---@class Struct
  local struct = {}
  struct.add = add
  struct.constant = constant
  struct.readFile = readFile
  struct.readHandle = readHandle
  struct.readString = readString
  struct.writeFile = writeFile
  struct.writeHandle = writeHandle
  struct.writeString = writeString
  struct.conditional = conditional
  struct.name = name
  struct.structure = {}
  structs[name] = struct
  return struct
end

---Get a created struct by name
---@param name string
---@return Struct
local function getStruct(name)
  return structs[name]
end

---Add a primative type
---@param type string
---@generic T : any
---@param reader fun(f: handle): T
---@param writer fun(f: handle, v: T)
local function addType(type, reader, writer)
  structReaders[type] = reader
  structWriters[type] = writer
end

---Get a reader for a datatype
---@param datatype string
---@generic T : any
---@return fun(f: handle): T
local function getReader(datatype)
  return select(1, getReaderWriter(datatype))
end

---Get a writer for a datatype
---@param datatype string
---@generic T : any
---@return fun(f: handle, v: T)
local function getWriter(datatype)
  return select(2, getReaderWriter(datatype))
end

return {
  newStruct=newStruct,
  getStruct=getStruct,
  addType=addType,
  getReaderWriter=getReaderWriter,
  getReader=getReader,
  getWriter=getWriter,
  stringHandle = stringHandle,
}
