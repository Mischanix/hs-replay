ffi = require "ffi"
{ :lshift, :rshift, :bxor, :bor, :band, :bnot } = require "bit"

ffi.cdef[[
typedef struct {
	uint32_t lo;
	uint32_t hi;
	uint32_t c;
} range;
]]

s32 = ffi.typeof "int32_t"
u32 = ffi.typeof "uint32_t"
s64 = ffi.typeof "int64_t"
u64 = ffi.typeof "uint64_t"
range = ffi.typeof "range"
Range = ->
	r = range!
	r.lo = 0
	r.hi = bnot 0
	r.c = 0 -- accumulator for the decoder
	r

kProbBits = 15LL
kProbMax = lshift(1, kProbBits)

char = string.char
ord = string.byte

class Buffer
	new: (data = '') =>
		@data = data

	append: (byt) =>
		@data ..= char(tonumber(band(byt, 0xff)))
		return

	at: (i) =>
		i = 1 + tonumber(i)
		ord @data\sub(i, i)

class BinArithEncoder
	new: (dest) =>
		@r = Range!
		@buf = dest

	finish: =>
		for i = 0,3
			@buf\append(rshift(@r.lo, 24))
			@r.lo = lshift(@r.lo, 8)
		return

	encode: (bit, prob) =>
		x = @r.lo + rshift(u64(@r.hi - @r.lo) * prob, kProbBits)

		if bit
			@r.hi = x
		else
			@r.lo = x + 1

		while u32(bxor(@r.lo, @r.hi)) < lshift(1, 24)
			@buf\append(rshift(@r.lo, 24))
			@r.lo = lshift(@r.lo, 8)
			@r.hi = bor(lshift(@r.hi, 8), 0xff)
		return

class BinArithDecoder
	new: (src) =>
		@r = Range!
		@buf = src
		@read_pos = 0LL
		for i = 0,3
			@r.c = bor(lshift(@r.c, 8), @buf\at(@read_pos))
			@read_pos += 1

	decode: (prob) =>
		bit = false
		x = @r.lo + u32(rshift(u64(@r.hi - @r.lo) * prob, kProbBits))

		if @r.c <= x
			@r.hi = x
			bit = true
		else
			@r.lo = x + 1

		while u32(bxor(@r.lo, @r.hi)) < lshift(1, 24)
			@r.c = bor(lshift(@r.c, 8), @buf\at(@read_pos))
			@read_pos += 1
			@r.lo = lshift(@r.lo, 8)
			@r.hi = bor(lshift(@r.hi, 8), 0xff)
		bit

class BinShiftModel
	new: (inertia) =>
		@prob = kProbMax / 2
		@inertia = inertia

	encode: (enc, bit) =>
		enc\encode(bit, @prob)
		@adapt bit
		return

	decode: (dec) =>
		bit = dec\decode @prob
		@adapt bit
		bit

	adapt: (bit) =>
		if bit
			@prob += rshift(kProbMax - @prob, @inertia)
		else
			@prob -= rshift(@prob, @inertia)
		return

class BitTreeModel
	new: (base, bits) =>
		@kNumSyms = lshift(1, bits)
		@kMSB = rshift(@kNumSyms, 1)
		@models = {}
		for i = 1,@kNumSyms
			@models[i] = base!

	encode: (enc, value) =>
		ctx = 1LL
		while ctx < @kNumSyms
			bit = band(value, @kMSB) ~= 0
			value += value
			@models[tonumber(ctx)]\encode(enc, bit)
			ctx += ctx + s64(bit)
		return

	decode: (dec, value) =>
		ctx = 1LL
		while ctx < @kNumSyms
			ctx += ctx + s64(@models[tonumber(ctx)]\decode(dec))
		ctx - @kNumSyms

mag = (n) ->
	m = 0
	while n >= lshift(1, m)
		m += 1
	m

class UExpModel
	new: (base, bits) =>
		@mag = BitTreeModel(base, mag(bits - 1))
		@kMaxTop = math.min(7, bits - 2)
		@top = {}
		for i = 1,@kMaxTop+1
			@top[i] = base!

	encode: (enc, value) =>
		value += 1
		m = mag(value) - 1
		@mag\encode(enc, m)

		if m > 0
			mask = lshift(1, m - 1)
			mtop = if m < @kMaxTop then m else @kMaxTop
			@top[mtop]\encode(enc, band(value, mask) ~= 0)

			mask = rshift(mask, 1)
			while mask > 0
				enc\encode(band(value, mask) ~= 0, kProbMax / 2)
				mask = rshift(mask, 1)
		return

	decode: (dec) =>
		m = @mag\decode(dec)
		v = 1LL
		if m > 0
			mtop = if m < @kMaxTop then m else @kMaxTop
			v += v + s64(@top[mtop]\decode(dec))
			for i = 1,m-1
				v += v + s64(dec\decode(kProbMax / 2))
		v - 1

class SExpModel
	new: (mag_base, sign_base, bits) =>
		@abs_coder = UExpModel(mag_base, bits - 1)
		@sign = sign_base!

	encode: (enc, value) =>
		absv = if value < 0 then -value else value
		@abs_coder\encode(enc, absv)
		if absv > 0
			@sign\encode(enc, value < 0)
		return

	decode: (dec) =>
		absv = @abs_coder\decode(dec)
		if absv > 0
			if @sign\decode(dec)
				return -absv
		return absv

xkxkx = ->
	f = io.open 'coder.moon', 'r'
	str = f\read '*a'
	decomp = Buffer ''
	comp = Buffer ''
	coder = BinArithEncoder comp


	model = BitTreeModel((-> BinShiftModel(4)), 8)
	for i = 1,str\len!
		model\encode(coder, ord(str\sub(i, i)))
	coder\finish!

	-- io.write comp\to_string! .. "\n"

	model = BitTreeModel((-> BinShiftModel(4)), 8)
	decoder = BinArithDecoder comp
	for i = 1,str\len!
		decomp\append(model\decode(decoder))
	-- io.write decomp\to_string() .. "\n"
	io.write "#decomp=#{decomp.data\len!}, #comp=#{comp.data\len!}, ratio=#{comp.data\len!/decomp.data\len!}\n"

{ :enum_names, :enum_values } = require "enums"

class HistCoder
	new: (buf) =>
		if buf == nil
			@comp = Buffer!
			@coder = BinArithEncoder @comp
		else
			@decomp = buf
			@coder = BinArithDecoder @decomp
		@strings = {} -- refs are held to this in the code stream by index. it
		-- will be lzma'd along with some other crap separate to the code stream

		@last_eid = 0 -- hist entity id
		@last_tag_eid = 0 -- tag entity id
		@last_tag_step = 0
		@last_tag_turn = 0

		default = -> BinShiftModel(4) -- lower => adapt faster
		@m = {}
		@m.hist_kind = BitTreeModel(default, 3) -- max 8 history kinds
		@m.ntag = BitTreeModel(default, 6) -- max 63 tags per entity
		@m.tag = BitTreeModel(default, 9) -- max 512 GameTag enum values
		@m.special_tag = BitTreeModel(default, 9) -- for GameEntity and Players
		@m.eid_delta = SExpModel(default, default, 16) -- max 32k entities
		@m.strid = BitTreeModel(default, 10) -- max 1023 strings
		@m.tag_default = SExpModel(default, default, 32) -- all uncategorized tags
		@m.tag_atkhp = SExpModel(default, default, 32) -- attack and hp-like values
		@m.tag_eid_delta = SExpModel(default, default, 16)
		@m.tag_controller = BitTreeModel(default, 2) -- 0, 1, 2 generally
		@m.tag_10limits = BitTreeModel(default, 4) -- limits that are normally =10
		@m.tag_step_delta = SExpModel(default, default, 5)
		@m.tag_turns_in_play = UExpModel(default, 11) -- max 2048 turns in play
		@m.tag_turns_left = UExpModel(default, 4)
		@m.tag_turn_delta = SExpModel(default, default, 4)
		@m.tag_zone = BitTreeModel(default, 3)
		@m.tag_faction = BitTreeModel(default, 2)
		@m.tag_resources = BitTreeModel(default, 4)
		@m.tag_num_attacks = BitTreeModel(default, 3)
		@m.tag_default_bool = default!
		@m.tag_cost = UExpModel(default, 7) -- max 127 cost
		@m.bnet_id = default!
		@m.start_index = SExpModel(default, default, 32)
		@m.start_kind = BitTreeModel(default, 3)
		@m.meta_ninfo = UExpModel(default, 12) -- idk
		@m.meta_info = SExpModel(default, default, 32)
		@m.meta_type = BitTreeModel(default, 2)
		@m.meta_data = SExpModel(default, default, 32)

	encode: (hists) =>
		for hist in *hists
			@encode_hist(hist)

	encode_hist: (hist) =>
		kind_idx = enum_values.PowerHistoryKind[hist.kind]
		@m.hist_kind\encode(@coder, kind_idx)
		if hist.kind == "FULL_ENTITY" or hist.kind == "SHOW_ENTITY"
			@encode_entity hist.data
		elseif hist.kind == "HIDE_ENTITY"
			@encode_hide hist.data
		elseif hist.kind == "TAG_CHANGE"
			@encode_change hist.data
		elseif hist.kind == "CREATE_GAME"
			@encode_create hist.data
		elseif hist.kind == "POWER_START"
			@encode_start hist.data
		elseif hist.kind == "POWER_END"
			@encode_end hist.data
		elseif hist.kind == "META_DATA"
			@encode_metadata hist.data
		else
			error("bad hist.kind")
		return

	encode_entity: (o) =>
		if o.id and o.id ~= 0
			@encode_eid(o.id)
		else
			error("entity has no id?")
		@encode_tags(o.tags, o.id <= 3)
		name_index = 0
		if o.name ~= nil
			table.insert(@strings, o.name)
			name_index = #@strings
		@m.strid\encode(@coder, name_index)


	encode_tag: (name, value, is_special = false) =>
		name_value = enum_values.GameTag[name]
		if is_special
			@m.special_tag\encode(@coder, name_value)
		else
			@m.tag\encode(@coder, name_value)

		tag_value = value
		if type(value) == "string"
			-- convert to enum values
			if name == "NEXT_STEP" or name == "STEP"
				tag_value = enum_values.STEP[value]
			elseif name == "CLASS"
				tag_value = enum_values.CLASS[value]
			elseif name == "CARDRACE"
				tag_value = enum_values.CARDRACE[value]
			elseif name == "FACTION"
				tag_value = enum_values.FACTION[value]
			elseif name == "CARDTYPE"
				tag_value = enum_values.CARDTYPE[value]
			elseif name == "RARITY"
				tag_value = enum_values.RARITY[value]
			elseif name == "STATE"
				tag_value = enum_values.STATE[value]
			elseif name == "PLAYSTATE"
				tag_value = enum_values.PLAYSTATE[value]
			elseif name == "ENCHANTMENT_BIRTH_VISUAL" or name == "ENCHANTMENT_IDLE_VISUAL"
				tag_value = enum_values.ENCHANTMENT_VISUAL[value]
			elseif name == "ZONE"
				tag_value = enum_values.ZONE[value]
			elseif name == "CARD_SET"
				tag_value = enum_values.CARD_SET[value]
			elseif name == "MULLIGAN_STATE"
				tag_value = enum_values.MULLIGAN[value]
		-- value:
		if name == "HERO_ENTITY" or name == "ENTITY_ID" or name == "ATTACKING" or name == "DEFENDING"
			delta = tag_value - @last_tag_eid
			@last_tag_eid = tag_value
			@m.tag_eid_delta\encode(@coder, delta)
		elseif name == "CONTROLLER" or name == "TEAM_ID" or name == "PLAYER_ID"
			if tag_value >= 4
				error("controller value out of range")
			@m.tag_controller\encode(@coder, tag_value)
		elseif name == "MAXRESOURCES" or name == "MAXHANDSIZE" or name == "STARTHANDSIZE"
			if tag_value >= 16
				error("resource limit value out of range")
			@m.tag_10limits\encode(@coder, tag_value)
		elseif name == "NEXT_STEP" or name == "STEP"
			delta = tag_value - @last_tag_step
			@last_tag_step = tag_value
			@m.tag_step_delta\encode(@coder, delta)
		elseif name == "NUM_TURNS_IN_PLAY"
			@m.tag_turns_in_play\encode(@coder, tag_value)
		elseif name == "NUM_TURNS_LEFT"
			if tag_value >= 16
				error("NUM_TURNS_LEFT out of range")
			@m.tag_turns_left\encode(@coder, tag_value)
		elseif name == "TURN"
			delta = tag_value - @last_tag_turn
			@last_tag_turn = tag_value
			@m.tag_turn_delta\encode(@coder, delta)
		elseif name == "ZONE"
			@m.tag_zone\encode(@coder, tag_value)
		elseif name == "FACTION"
			@m.tag_faction\encode(@coder, tag_value)
		elseif name == "RESOURCES"
			@m.tag_resources\encode(@coder, tag_value)
		elseif name == "NUM_ATTACKS_THIS_TURN"
			if tag_value >= 8
				error("NUM_ATTACKS_THIS_TURN out of range")
			@m.tag_num_attacks\encode(@coder, tag_value)
		elseif name == "COST"
			@m.tag_cost\encode(@coder, tag_value)
		elseif @is_default_bool(name)
			@m.tag_default_bool\encode(@coder, tag_value)
		elseif @is_health_atk_like(name)
			@m.tag_atkhp\encode(@coder, tag_value)
		else
			@m.tag_default\encode(@coder, tag_value)
		return

	is_default_bool: (n) =>
		return true if n == "FIRST_PLAYER"
		return true if n == "CURRENT_PLAYER"
		return true if n == "EXHAUSTED"
		return true if n == "JUST_PLAYED"
		return true if n == "WINDFURY"
		return true if n == "STEALTH"
		return true if n == "ENRAGED"
		return true if n == "SILENCED"
		return true if n\sub(1,5) == "CANT_"
		return true if n == "TAUNT"
		return true if n == "RECENTLY_ARRIVED"
		return false

	is_health_atk_like: (n) =>
		return true if n == "HEALTH"
		return true if n == "ATK"
		return true if n == "DURABILITY"
		return true if n == "ARMOR"
		return false

	encode_eid: (eid) =>
		delta = eid - @last_eid
		@last_eid = eid
		@m.eid_delta\encode(@coder, delta)

	encode_tags: (tags, is_special = false) =>
		local ntags
		if tags ~= nil
			ntags = #tags
		else
			ntags = 0
		if ntags >= 64
			error("ntags exceeds maximum")
		@m.ntag\encode(@coder, ntags)
		for i = 1,ntags
			@encode_tag(tags[i].name, tags[i].value, is_special)
		return

	encode_hide: (o) =>
		@encode_eid(o.entity)
		@m.tag_zone\encode(@coder, o.zone)

	encode_change: (o) =>
		delta = o.entity - @last_eid
		@last_eid = o.entity
		@m.eid_delta\encode(@coder, delta)
		@encode_tag(o.tag, o.value, o.entity <= 3)

	encode_create: (o) =>
		@encode_eid(o.game_entity.id)
		@encode_tags(o.game_entity.tags, true)
		for i=1,2
			@encode_eid(o.players[i].id)
			@encode_bnet_id_word(o.players[i].gameAccountId.lo)
			@encode_bnet_id_word(o.players[i].gameAccountId.hi)
			@m.tag_default\encode(@coder, o.players[i].card_back)
			@encode_eid(o.players[i].entity.id)
			@encode_tags(o.players[i].entity.tags, true)

	encode_bnet_id_word: (w) =>
		for i=63,0
			@m.bnet_id\encode(@coder, band(lshift(1, i), w) ~= 0)

	encode_start: (o) =>
		@m.start_kind\encode(@coder, enum_values.PowerHistoryStartType[o.type])
		@m.start_index\encode(@coder, o.index)
		@encode_eid(o.source)
		delta = o.target - @last_tag_eid
		@last_tag_eid = o.target
		@m.tag_eid_delta\encode(@coder, delta)

	encode_end: (o) =>
		return -- just a tag

	encode_metadata: (o) =>
		@m.meta_ninfo\encode(@coder, #o.info)
		for i=1,#o.info
			@m.meta_info\encode(@coder, o.info[i])
		@m.meta_type\encode(@coder, o.meta_type + 1)
		@m.meta_data\encode(@coder, o.data)

	-- (( Decoders ))
	decode: =>
		result = {}
		for i=1,@nhists
			table.insert(result, @decode_hist!)
		result

	decode_hist: =>
		kind_idx = @m.hist_kind\decode(@decoder)
		kind = enum_names.PowerHistoryKind[kind_idx]
		if kind == "FULL_ENTITY" or kind == "SHOW_ENTITY"
			return @decode_entity!
		elseif kind == "HIDE_ENTITY"
			return @decode_hide!
		elseif kind == "TAG_CHANGE"
			return @decode_change!
		elseif kind == "CREATE_GAME"
			return @decode_create!
		elseif kind == "POWER_START"
			return @decode_start!
		elseif kind == "POWER_END"
			return @decode_end!
		elseif kind == "META_DATA"
			return @decode_metadata!
		else
			error("bad hist.kind")

	decode_entity: =>
		o = {}
		o.id = @decode_eid
		o.tags = @decode_tags(o.id <= 3)
		name_index = @m.strid\decode(@decoder)
		if name_index > 0
			o.name = @strings[name_index]
		return o
