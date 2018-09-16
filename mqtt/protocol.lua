-- DOC: http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/errata01/os/mqtt-v3.1.1-errata01-os-complete.html

--[[

CONVENTIONS:

	* read_func - function to read data from some stream-like object (like network connection).
		We are calling it with one argument: number of bytes to read.
		Use currying to pass other arguments to this function.
		This function should return string of given size on success.
		On failure it should return false/nil and an error message.

]]

-- module table
local protocol = {}

-- required modules
local table = require("table")
local string = require("string")
local bit = require("mqtt.bit")
local tools = require("mqtt.tools")


-- cache to locals
local assert = assert
local tostring = tostring
local setmetatable = setmetatable
local error = error
local tbl_concat = table.concat
local str_sub = string.sub
local str_char = string.char
local str_byte = string.byte
local str_format = string.format
local bor = bit.bor
local band = bit.band
local lshift = bit.lshift
local rshift = bit.rshift
local div = tools.div
local unpack = unpack or table.unpack


-- Create uint8 value data
local function make_uint8(val)
	if val < 0 or val > 0xFF then
		error("value is out of range to encode as uint8: "..tostring(val))
	end
	return str_char(val)
end
protocol.make_uint8 = make_uint8

-- Create uint16 value data
local function make_uint16(val)
	if val < 0 or val > 0xFFFF then
		error("value is out of range to encode as uint16: "..tostring(val))
	end
	return str_char(rshift(val, 8), band(val, 0xFF))
end
protocol.make_uint16 = make_uint16

-- Create UTF-8 string data, DOC: 1.5.3 UTF-8 encoded strings
local function make_string(str)
	return make_uint16(str:len())..str
end
protocol.make_string = make_string

-- Returns bytes of given integer value encoded as variable length field, DOC: 2.2.3 Remaining Length
local function make_var_length(len)
	if len < 0 or len > 268435455 then
		error("value is invalid for encoding as variable length field: "..tostring(len))
	end
	local bytes = {}
	local i = 1
	repeat
		local byte = len % 128
		len = div(len, 128)
		if len > 0 then
			byte = bor(byte, 128)
		end
		bytes[i] = byte
		i = i + 1
	until len <= 0
	return unpack(bytes)
end
protocol.make_var_length = make_var_length

-- Create fixed packet header data, DOC: 2.2 Fixed header
local function make_header(ptype, flags, len)
	local byte1 = bor(lshift(ptype, 4), band(flags, 0x0F))
	return str_char(byte1, make_var_length(len))
end

-- MQTT protocol fixed header packet types, DOC: 2.2.1 MQTT Control Packet type
local packet_type = {
	CONNECT = 			1,
	CONNACK = 			2,
	PUBLISH = 			3,
	PUBACK = 			4,
	PUBREC = 			5,
	PUBREL = 			6,
	PUBCOMP = 			7,
	SUBSCRIBE = 		8,
	SUBACK = 			9,
	UNSUBSCRIBE = 		10,
	UNSUBACK = 			11,
	PINGREQ = 			12,
	PINGRESP = 			13,
	DISCONNECT = 		14,
	[1] = 				"CONNECT",
	[2] = 				"CONNACK",
	[3] = 				"PUBLISH",
	[4] = 				"PUBACK",
	[5] = 				"PUBREC",
	[6] = 				"PUBREL",
	[7] = 				"PUBCOMP",
	[8] = 				"SUBSCRIBE",
	[9] = 				"SUBACK",
	[10] = 				"UNSUBSCRIBE",
	[11] = 				"UNSUBACK",
	[12] = 				"PINGREQ",
	[13] = 				"PINGRESP",
	[14] = 				"DISCONNECT",
}
protocol.packet_type = packet_type

-- Packet types requiring packet identifier field
-- DOC: 2.3.1 Packet Identifier
local packets_requiring_packet_id = {
	[packet_type.PUBACK] 		= true,
	[packet_type.PUBREC] 		= true,
	[packet_type.PUBREL] 		= true,
	[packet_type.PUBCOMP] 		= true,
	[packet_type.SUBSCRIBE] 	= true,
	[packet_type.SUBACK] 		= true,
	[packet_type.UNSUBSCRIBE] 	= true,
	[packet_type.UNSUBACK] 		= true,
}

-- CONNACK return code strings
protocol.connack_return_code = {
	[0] = "Connection Accepted",
	[1] = "Connection Refused, unacceptable protocol version",
	[2] = "Connection Refused, identifier rejected",
	[3] = "Connection Refused, Server unavailable",
	[4] = "Connection Refused, bad user name or password",
	[5] = "Connection Refused, not authorized",
}

-- Returns true if given value is a valid QoS
local function check_qos(val)
	return (val == 0) or (val == 1) or (val == 2)
end

-- Returns true if given value is a valid Packet Identifier
local function check_packet_id(val)
	return val >= 1 and val <= 0xFFFF
end

-- Returns the next Packet Identifier value relative to given current value
function protocol.next_packet_id(curr)
	if not curr then
		return 1
	end
	assert(type(curr) == "number", "expecting curr to be a number")
	assert(curr >= 1, "expecting curr to be >= 1")
	curr = curr + 1
	if curr > 0xFFFF then
		curr = 1
	end
	return curr
end

-- Returns true if Packet Identifier field are required for given packet
function protocol.packet_id_required(args)
	assert(type(args) == "table", "expecting args to be a table")
	assert(type(args.type) == "number", "expecting .type to be a table")
	local ptype = args.type
	if ptype == packet_type.PUBLISH and args.qos > 0 then
		return true
	end
	return packets_requiring_packet_id[ptype]
end

-- Create Connect Flags data, DOC: 3.1.2.3 Connect Flags
local function make_connect_flags(args)
	local byte = 0 -- bit 0 should be zero
	-- DOC: 3.1.2.4 Clean Session
	if args.clean ~= nil then
		assert(type(args.clean) == "boolean", "expecting .clean to be a boolean")
		if args.clean then
			byte = bor(byte, lshift(1, 1))
		end
	end
	-- DOC: 3.1.2.5 Will Flag
	if args.will ~= nil then
		-- check required args are presented
		assert(type(args.will) == "table", "expecting .will to be a table")
		assert(type(args.will.message) == "string", "expecting .will.message to be a string")
		assert(type(args.will.topic) == "string", "expecting .will.topic to be a string")
		assert(type(args.will.qos) == "number", "expecting .will.qos to be a number")
		assert(check_qos(args.will.qos), "expecting .will.qos to be a valid QoS value")
		assert(type(args.will.retain) == "boolean", "expecting .will.retain to be a boolean")
		-- will flag should be set to 1
		byte = bor(byte, lshift(1, 2))
		-- DOC: 3.1.2.6 Will QoS
		byte = bor(byte, lshift(args.will.qos, 3))
		-- DOC: 3.1.2.7 Will Retain
		if args.will.retain then
			byte = bor(byte, lshift(1, 5))
		end
	end
	-- DOC: 3.1.2.8 User Name Flag
	if args.username ~= nil then
		assert(type(args.username) == "string", "expecting .username to be a string")
		byte = bor(byte, lshift(1, 7))
	end
	-- 3.1.2.9 Password Flag
	if args.password ~= nil then
		assert(type(args.password) == "string", "expecting .password to be a string")
		assert(args.username, "the .username is required to set .password")
		byte = bor(byte, lshift(1, 6))
	end
	return make_uint8(byte)
end

-- Metatable for combined data packet, should looks like a string
local combined_packet_mt = {
	-- Convert combined data packet to string
	__tostring = function(self)
		local strings = {}
		for i, part in ipairs(self) do
			strings[i] = tostring(part)
		end
		return tbl_concat(strings)
	end,

	-- Get length of combined data packet
	len = function(self)
		local len = 0
		for _, part in ipairs(self) do
			len = len + part:len()
		end
		return len
	end,

	-- Append part to the end of combined data packet
	append = function(self, part)
		self[#self + 1] = part
	end
}

-- Make combined_packet_mt table works like a class
combined_packet_mt.__index = function(_, key)
	return combined_packet_mt[key]
end

-- Combine several data parts into one
local function combine(...)
	return setmetatable({...}, combined_packet_mt)
end

-- Create CONNECT packet, DOC: 3.1 CONNECT – Client requests a connection to a Server
local function make_packet_connect(args)
	-- check args
	assert(type(args.id) == "string", "expecting .id to be a string with MQTT client id")
	-- DOC: 3.1.2.10 Keep Alive
	local keep_alive_ival = 0
	if args.keep_alive then
		assert(type(args.keep_alive) == "number")
		keep_alive_ival = args.keep_alive
	end
	-- DOC: 3.1.2 Variable header
	local variable_header = combine(
		make_string("MQTT"), 				-- DOC: 3.1.2.1 Protocol Name
		make_uint8(4), 						-- DOC: 3.1.2.2 Protocol Level (4 is for MQTT v3.1.1)
		make_connect_flags(args), 			-- DOC: 3.1.2.3 Connect Flags
		make_uint16(keep_alive_ival) 		-- DOC: 3.1.2.10 Keep Alive
	)
	-- DOC: 3.1.3 Payload
	-- DOC: 3.1.3.1 Client Identifier
	local payload = combine(
		make_string(args.id)
	)
	if args.will then
		-- DOC: 3.1.3.2 Will Topic
		payload:append(make_string(args.will.topic))
		-- DOC: 3.1.3.3 Will Message
		payload:append(make_string(args.will.message))
	end
	if args.username then
		-- DOC: 3.1.3.4 User Name
		payload:append(make_string(args.username))
		if args.password then
			-- DOC: 3.1.3.5 Password
			payload:append(make_string(args.password))
		end
	end
	-- DOC: 3.1.1 Fixed header
	local header = make_header(packet_type.CONNECT, 0, variable_header:len() + payload:len())
	return combine(header, variable_header, payload)
end

-- Create PUBLISH packet, DOC: 3.3 PUBLISH – Publish message
local function make_packet_publish(args)
	-- check args
	assert(type(args.topic) == "string", "expecting .topic to be a string")
	if args.payload ~= nil then
		assert(type(args.payload) == "string", "expecting .payload to be a string")
	end
	assert(type(args.qos) == "number", "expecting .qos to be a number")
	assert(check_qos(args.qos), "expecting .qos to be a valid QoS value")
	assert(type(args.retain) == "boolean", "expecting .retain to be a boolean")
	assert(type(args.dup) == "boolean", "expecting .dup to be a boolean")
	-- DOC: 3.3.1 Fixed header
	local flags = 0
	-- 3.3.1.3 RETAIN
	if args.retain then
		flags = bor(flags, 0x1)
	end
	-- DOC: 3.3.1.2 QoS
	flags = bor(flags, lshift(args.qos, 1))
	-- DOC: 3.3.1.1 DUP
	if args.dup then
		flags = bor(flags, lshift(1, 3))
	end
	-- DOC: 3.3.2  Variable header
	local variable_header = combine(
		make_string(args.topic)
	)
	-- DOC: 3.3.2.2 Packet Identifier
	if args.qos > 0 then
		assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
		assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
		variable_header:append(make_uint16(args.packet_id))
	end
	local payload
	if args.payload then
		payload = args.payload
	else
		payload = ""
	end
	-- DOC: 3.3.1 Fixed header
	local header = make_header(packet_type.PUBLISH, flags, variable_header:len() + payload:len())
	return combine(header, variable_header, payload)
end

-- Create PUBACK packet, DOC: 3.4 PUBACK – Publish acknowledgement
local function make_packet_puback(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	-- DOC: 3.4.1 Fixed header
	local header = make_header(packet_type.PUBACK, 0, 2)
	-- DOC: 3.4.2 Variable header
	local variable_header = make_uint16(args.packet_id)
	return combine(header, variable_header)
end

-- Create PUBREC packet, DOC: 3.5 PUBREC – Publish received (QoS 2 publish received, part 1)
local function make_packet_pubrec(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	-- DOC: 3.5.1 Fixed header
	local header = make_header(packet_type.PUBREC, 0, 2)
	-- DOC: 3.5.2 Variable header
	local variable_header = make_uint16(args.packet_id)
	return combine(header, variable_header)
end

-- Create PUBREL packet, DOC: 3.6 PUBREL – Publish release (QoS 2 publish received, part 2)
local function make_packet_pubrel(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	-- DOC: 3.6.1 Fixed header
	local header = make_header(packet_type.PUBREL, 0x2, 2) -- flags are 0x2 == 0010 bits (fixed value)
	-- DOC: 3.6.2 Variable header
	local variable_header = make_uint16(args.packet_id)
	return combine(header, variable_header)
end

-- Create PUBCOMP packet, DOC: 3.7 PUBCOMP – Publish complete (QoS 2 publish received, part 3)
local function make_packet_pubcomp(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	-- DOC: 3.7.1 Fixed header
	local header = make_header(packet_type.PUBCOMP, 0, 2)
	-- DOC: 3.7.2 Variable header
	local variable_header = make_uint16(args.packet_id)
	return combine(header, variable_header)
end

-- Create SUBSCRIBE packet, DOC: 3.8 SUBSCRIBE - Subscribe to topics
local function make_packet_subscribe(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	assert(type(args.subscriptions) == "table", "expecting .subscriptions to be a table")
	assert(#args.subscriptions > 0, "expecting .subscriptions to be a non-empty array")
	-- DOC: 3.8.2 Variable header
	local variable_header = combine(
		make_uint16(args.packet_id)
	)
	-- DOC: 3.8.3 Payload
	local payload = combine()
	for i, subscription in ipairs(args.subscriptions) do
		assert(type(subscription) == "table", "expecting .subscriptions["..i.."] to be a table")
		assert(type(subscription.topic) == "string", "expecting .subscriptions["..i.."].topic to be a string")
		if subscription.qos ~= nil then
			assert(type(subscription.qos) == "number", "expecting .subscriptions["..i.."].qos to be a number")
			assert(check_qos(subscription.qos), "expecting .subscriptions["..i.."].qos to be a valid QoS value")
		end
		payload:append(make_string(subscription.topic))
		payload:append(make_uint8(subscription.qos or 0))
	end
	-- DOC: 3.8.1 Fixed header
	local header = make_header(packet_type.SUBSCRIBE, 2, variable_header:len() + payload:len()) -- NOTE: fixed flags value 0x2
	return combine(header, variable_header, payload)
end

-- Create UNSUBSCRIBE packet, DOC: 3.10 UNSUBSCRIBE – Unsubscribe from topics
local function make_packet_unsubscribe(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	assert(type(args.subscriptions) == "table", "expecting .subscriptions to be a table")
	assert(#args.subscriptions > 0, "expecting .subscriptions to be a non-empty array")
	-- DOC: 3.10.2 Variable header
	local variable_header = combine(
		make_uint16(args.packet_id)
	)
	-- DOC: 3.10.3 Payload
	local payload = combine()
	for i, subscription in ipairs(args.subscriptions) do
		assert(type(subscription) == "string", "expecting .subscriptions["..i.."] to be a string")
		payload:append(make_string(subscription))
	end
	-- DOC: 3.10.1 Fixed header
	local header = make_header(packet_type.UNSUBSCRIBE, 2, variable_header:len() + payload:len()) -- NOTE: fixed flags value 0x2
	return combine(header, variable_header, payload)
end

-- Create packet of given {type: number} in args
function protocol.make_packet(args)
	assert(type(args) == "table", "expecting args to be a table")
	assert(type(args.type) == "number", "expecting .type number in args")
	local ptype = args.type
	if ptype == packet_type.CONNECT then
		return make_packet_connect(args)
	elseif ptype == packet_type.PUBLISH then
		return make_packet_publish(args)
	elseif ptype == packet_type.PUBACK then
		return make_packet_puback(args)
	elseif ptype == packet_type.PUBREC then
		return make_packet_pubrec(args)
	elseif ptype == packet_type.PUBREL then
		return make_packet_pubrel(args)
	elseif ptype == packet_type.PUBCOMP then
		return make_packet_pubcomp(args)
	elseif ptype == packet_type.SUBSCRIBE then
		return make_packet_subscribe(args)
	elseif ptype == packet_type.UNSUBSCRIBE then
		return make_packet_unsubscribe(args)
	elseif ptype == packet_type.PINGREQ then
		-- DOC: 3.12 PINGREQ – PING request
		return combine("\192\000") -- 192 == 0xC0, type == 12, flags == 0
	elseif ptype == packet_type.DISCONNECT then
		-- DOC: 3.14 DISCONNECT – Disconnect notification
		return combine("\224\000") -- 224 == 0xD0, type == 14, flags == 0
	else
		error("unexpected packet type to make: "..args.type)
	end
end

local max_mult = 128 * 128 * 128

-- Returns variable length field value calling read_func function read data, DOC: 2.2.3 Remaining Length
local function parse_var_length(read_func)
	assert(type(read_func) == "function", "expecting read_func to be a function")
	local mult = 1
	local val = 0
	repeat
		local byte, err = read_func(1)
		if not byte then
			return false, err
		end
		byte = str_byte(byte, 1, 1)
		val = val + band(byte, 127) * mult
		if mult > max_mult then
			return false, "malformed variable length field data"
		end
		mult = mult * 128
	until band(byte, 128) == 0
	return val
end
protocol.parse_var_length = parse_var_length

-- Convert packet to string representation
local function packet_tostring(packet)
	local res = {}
	for k, v in pairs(packet) do
		res[#res + 1] = str_format("%s=%s", k, tostring(v))
	end
	return str_format("%s{%s}", tostring(packet_type[packet.type]), tbl_concat(res, ", "))
end
protocol.packet_tostring = packet_tostring

-- Parsed packet metatable
local packet_mt = {
	__tostring = packet_tostring,
}

-- Parse packet using given read_func
-- Returns packet on success or false and error message on failure
function protocol.parse_packet(read_func)
	assert(type(read_func) == "function", "expecting read_func to be a function")
	-- parse fixed header
	local byte1, byte2, err, len, data, rc
	byte1, err = read_func(1)
	if not byte1 then
		return false, err
	end
	byte1 = str_byte(byte1, 1, 1)
	local ptype = rshift(byte1, 4)
	local flags = band(byte1, 0xF)
	len, err = parse_var_length(read_func)
	if not len then
		return false, err
	end
	if len > 0 then
		data, err = read_func(len)
	else
		data = ""
	end
	if not data then
		return false, err
	end
	local data_len = data:len()
	-- parse readed data according type in fixed header
	if ptype == packet_type.CONNACK then
		-- DOC: 3.2 CONNACK – Acknowledge connection request
		if data_len ~= 2 then
			return false, "expecting data of length 2 bytes"
		end
		byte1, byte2 = str_byte(data, 1, 2)
		local sp = (band(byte1, 0x1) ~= 0)
		return setmetatable({type=ptype, sp=sp, rc=byte2}, packet_mt)
	elseif ptype == packet_type.PUBLISH then
		-- DOC: 3.3 PUBLISH – Publish message
		-- DOC: 3.3.1.1 DUP
		local dup = (band(flags, 0x8) ~= 0)
		-- DOC: 3.3.1.2 QoS
		local qos = band(rshift(flags, 1), 0x3)
		-- DOC: 3.3.1.3 RETAIN
		local retain = (band(flags, 0x1) ~= 0)
		-- DOC: 3.3.2.1 Topic Name
		if data_len < 2 then
			return false, "expecting data of length at least 2 bytes"
		end
		byte1, byte2 = str_byte(data, 1, 2)
		local topic_len = bor(lshift(byte1, 8), byte2)
		if data_len < 2 + topic_len then
			return false, "malformed PUBLISH packet: not enough data to parse topic"
		end
		local topic = str_sub(data, 3, 3 + topic_len - 1)
		-- DOC: 3.3.2.2 Packet Identifier
		local packet_id, packet_id_len = nil, 0
		if qos > 0 then
			-- DOC: 3.3.2.2 Packet Identifier
			if data_len < 2 + topic_len + 2 then
				return false, "malformed PUBLISH packet: not enough data to parse packet_id"
			end
			byte1, byte2 = str_byte(data, 3 + topic_len, 3 + topic_len + 1)
			packet_id = bor(lshift(byte1, 8), byte2)
			packet_id_len = 2
		end
		-- DOC: 3.3.3 Payload
		local payload
		if data_len > 2 + topic_len + packet_id_len then
			payload = str_sub(data, 2 + topic_len + packet_id_len + 1)
		end
		return setmetatable({type=ptype, dup=dup, qos=qos, retain=retain, packet_id=packet_id, topic=topic, payload=payload}, packet_mt)
	elseif ptype == packet_type.PUBACK then
		-- DOC: 3.4 PUBACK – Publish acknowledgement
		if data_len ~= 2 then
			return false, "expecting data of length 2 bytes"
		end
		-- DOC: 3.4.2 Variable header
		byte1, byte2 = str_byte(data, 1, 2)
		return setmetatable({type=ptype, packet_id=bor(lshift(byte1, 8), byte2)}, packet_mt)
	elseif ptype == packet_type.PUBREC then
		-- DOC: 3.5 PUBREC – Publish received (QoS 2 publish received, part 1)
		if data_len ~= 2 then
			return false, "expecting data of length 2 bytes"
		end
		-- DOC: 3.5.2 Variable header
		byte1, byte2 = str_byte(data, 1, 2)
		return setmetatable({type=ptype, packet_id=bor(lshift(byte1, 8), byte2)}, packet_mt)
	elseif ptype == packet_type.PUBREL then
		-- DOC: 3.6 PUBREL – Publish release (QoS 2 publish received, part 2)
		if data_len ~= 2 then
			return false, "expecting data of length 2 bytes"
		end
		-- also flags should be checked to equals 2 by the server
		-- DOC: 3.6.2 Variable header
		byte1, byte2 = str_byte(data, 1, 2)
		return setmetatable({type=ptype, packet_id=bor(lshift(byte1, 8), byte2)}, packet_mt)
	elseif ptype == packet_type.PUBCOMP then
		-- 3.7 PUBCOMP – Publish complete (QoS 2 publish received, part 3)
		if data_len ~= 2 then
			return false, "expecting data of length 2 bytes"
		end
		-- DOC: 3.7.2 Variable header
		byte1, byte2 = str_byte(data, 1, 2)
		return setmetatable({type=ptype, packet_id=bor(lshift(byte1, 8), byte2)}, packet_mt)
	elseif ptype == packet_type.SUBACK then
		-- DOC: 3.9 SUBACK – Subscribe acknowledgement
		if data_len ~= 3 then
			return false, "expecting data of length 3 bytes"
		end
		-- DOC: 3.9.2 Variable header
		-- DOC: 3.9.3 Payload
		byte1, byte2, rc = str_byte(data, 1, 3)
		return setmetatable({type=ptype, packet_id=bor(lshift(byte1, 8), byte2), rc=rc, failure=(rc == 0x80)}, packet_mt)
	elseif ptype == packet_type.UNSUBACK then
		-- DOC: 3.11 UNSUBACK – Unsubscribe acknowledgement
		if data_len ~= 2 then
			return false, "expecting data of length 2 bytes"
		end
		-- DOC: 3.11.2 Variable header
		byte1, byte2 = str_byte(data, 1, 2)
		return setmetatable({type=ptype, packet_id=bor(lshift(byte1, 8), byte2)}, packet_mt)
	elseif ptype == packet_type.PINGRESP then
		-- DOC: 3.13 PINGRESP – PING response
		if data_len ~= 0 then
			return false, "expecting data of length 0 bytes"
		end
		return setmetatable({type=ptype}, packet_mt)
	else
		return false, "unexpected packet type received: "..tostring(ptype)
	end
end

-- export module table
return protocol

-- vim: ts=4 sts=4 sw=4 noet ft=lua
