ffi = require "ffi"
{ :lshift, :rshift, :bxor, :bor, :band, :bnot } = require "bit"

ffi.cdef[[
typedef struct {
	uint32_t lo;
	uint32_t hi;
	uint32_t c;
} range;

/* lzma imports */
int lzma_easy_buffer_encode(int preset, int check, void *allocator,
	const uint8_t *in, size_t in_size,
	uint8_t *out, size_t *out_pos, size_t out_size);

int lzma_stream_buffer_decode(uint64_t *memlimit, uint32_t flags,
	void *allocator, const uint8_t *in, size_t *in_pos, size_t in_size,
	uint8_t *out, size_t *out_pos, size_t out_size);
]]

lzma = ffi.load "lzma"
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
		return tonumber(ctx - @kNumSyms)

mag = (n) ->
	m = 0
	while n >= lshift(1LL, m)
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
			for i = 1, tonumber(m-1)
				v += v + s64(dec\decode(kProbMax / 2))
		return tonumber(v - 1)

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
		@name_to_idx = {}

		@last_eid = 0 -- hist entity id
		@last_tag_eid = 0 -- tag entity id
		@last_tag_step = 0
		@last_tag_turn = 0
		@last_turn_start = 1356998400 -- January 1, 2013 "Hearthstone Epoch" :P
		@last_tag_ignore_damage = false
		@last_time = 0.0
		@expect_tag_options_played = 0

		@action_depth = 0

		default = -> BinShiftModel(4) -- lower => adapt faster
		@m = {}
		@m.hist_time = UExpModel(default, 31)
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
		@m.tag_turn_start_delta = UExpModel(default, 31)
		@m.tag_zone = BitTreeModel(default, 3)
		@m.tag_zone_position = UExpModel(default, 4)
		@m.tag_faction = BitTreeModel(default, 2)
		@m.tag_resources = BitTreeModel(default, 4)
		@m.tag_num_attacks = BitTreeModel(default, 3)
		@m.tag_default_bool = default!
		@m.tag_cost = UExpModel(default, 7) -- max 127 cost
		@m.tag_damage = UExpModel(default, 31)
		@m.tag_ignore_damage = default!
		@m.tag_options_played_delta = SExpModel(default, default, 12)
		@m.bnet_id = default!
		@m.start_index = SExpModel(default, default, 8)
		@m.start_kind = BitTreeModel(default, 3)
		@m.meta_ninfo = UExpModel(default, 12) -- idk
		@m.meta_info = SExpModel(default, default, 32)
		@m.meta_type = BitTreeModel(default, 2)
		@m.meta_data = SExpModel(default, default, 32)

	encode: (hists) =>
		for hist in *hists
			@encode_hist(hist)

	encode_hist: (hist) =>
		{ :time, :kind, :data } = hist

		dtime = time - @last_time
		if dtime < 0
			error("time has flown backwards")
		dtime_ms = math.floor(dtime * 1000)
		@last_time += dtime_ms / 1000
		@m.hist_time\encode(@coder, dtime_ms)

		kind_idx = enum_values.PowerHistoryKind[kind] - 1
		@m.hist_kind\encode(@coder, kind_idx)
		if kind == "FULL_ENTITY" or kind == "SHOW_ENTITY"
			@encode_entity data
		elseif kind == "HIDE_ENTITY"
			@encode_hide data
		elseif kind == "TAG_CHANGE"
			@encode_change data
		elseif kind == "CREATE_GAME"
			@last_tag_turn = 0
			@encode_create data
		elseif kind == "POWER_START"
			@encode_start data
		elseif kind == "POWER_END"
			@encode_end data
		elseif kind == "META_DATA"
			@encode_metadata data
		else
			error("bad hist.kind: #{kind}")
		return

	encode_entity: (o) =>
		if o.entity and o.entity ~= 0
			@encode_eid(o.entity)
		else
			error("entity has no id? (id = #{o.entity})")
		@encode_tags(o.tags, o.entity <= 3)
		name_index = 0
		if o.name ~= nil
			name_index = @get_name_index(o.name)
		@m.strid\encode(@coder, name_index)

	get_name_index: (name) =>
		if @name_to_idx[name] ~= nil
			return @name_to_idx[name]

		table.insert(@strings, name)
		@name_to_idx[name] = #@strings
		return #@strings

	encode_tag: (name, value, is_special = false) =>
		local name_value
		if type(name) == "string"
			name_value = enum_values.GameTag[name]
		else
			name_value = name
			name = ""
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

		if name == "STEP" and tag_value == enum_values.STEP.MAIN_START
			-- beginning of turn actions phase:
			@expect_tag_options_played = 0

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
		elseif name == "TURN_START" -- unix timestamp
			delta = tag_value - @last_turn_start
			@last_turn_start = tag_value
			@m.tag_turn_start_delta\encode(@coder, delta)
		elseif name == "ZONE"
			@m.tag_zone\encode(@coder, tag_value)
		elseif name == "ZONE_POSITION"
			@m.tag_zone_position\encode(@coder, tag_value)
		elseif name == "FACTION"
			@m.tag_faction\encode(@coder, tag_value)
		elseif name == "RESOURCES"
			@m.tag_resources\encode(@coder, tag_value)
		elseif name == "NUM_ATTACKS_THIS_TURN"
			if tag_value >= 8
				error("NUM_ATTACKS_THIS_TURN out of range")
			@m.tag_num_attacks\encode(@coder, tag_value)
		elseif name == "NUM_OPTIONS_PLAYED_THIS_TURN"
			delta = tag_value - @expect_tag_options_played
			@expect_tag_options_played = tag_value
			@m.tag_options_played_delta\encode(@coder, delta)
		elseif name == "COST"
			@m.tag_cost\encode(@coder, tag_value)
		elseif name == "PREDAMAGE" or name == "DAMAGE"
			@m.tag_damage\encode(@coder, tag_value)
		elseif name == "IGNORE_DAMAGE" -- these two are in a relationship
			tag_bool = tag_value ~= 0
			expect = not @last_tag_ignore_damage
			@last_tag_ignore_damage = tag_bool
			@m.tag_ignore_damage\encode(@coder, expect == tag_bool)
		elseif name == "IGNORE_DAMAGE_OFF"
			tag_bool = tag_value ~= 0
			expect = @last_tag_ignore_damage
			@m.tag_ignore_damage\encode(@coder, expect == tag_bool)
		elseif @is_default_bool(name)
			if tag_value > 1 or tag_value < 0
				error("bool tag out of range")
			@m.tag_default_bool\encode(@coder, tag_value ~= 0)
		elseif @is_health_atk_like(name)
			@m.tag_atkhp\encode(@coder, tag_value)
		else
			@m.tag_default\encode(@coder, tag_value)
		return

	is_default_bool: (n) =>
		return false if type(n) ~= "string"
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
		zone_value = enum_values.ZONE[o.zone]
		@m.tag_zone\encode(@coder, zone_value)

	encode_change: (o) =>
		@encode_eid(o.entity)
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
		if @action_depth == 0 and o.type == "PLAY"
			@expect_tag_options_played += 1
		@action_depth += 1

		@m.start_kind\encode(@coder, enum_values.PowerHistoryStartType[o.type])
		@m.start_index\encode(@coder, o.index)
		@encode_eid(o.source)
		delta = o.target - @last_tag_eid
		@last_tag_eid = o.target
		@m.tag_eid_delta\encode(@coder, delta)

	encode_end: (o) =>
		@action_depth -= 1
		return -- just a tag

	encode_metadata: (o) =>
		@m.meta_ninfo\encode(@coder, #o.info)
		for i=1,#o.info
			@m.meta_info\encode(@coder, o.info[i])
		meta_type = enum_values.PowerHistoryMetaType[o.meta_type]
		@m.meta_type\encode(@coder, meta_type + 1)
		@m.meta_data\encode(@coder, o.data)

	-- (( Decoders ))
	decode: =>
		result = {}
		for i=1,@nhists
			table.insert(result, @decode_hist!)
		result

	decode_hist: =>
		dtime_ms = @m.hist_time\decode(@coder)
		dtime = dtime_ms / 1000
		time = @last_time + dtime
		@last_time = time

		kind_idx = @m.hist_kind\decode(@coder) + 1
		kind = enum_names.PowerHistoryKind[kind_idx]
		local data
		if kind == "FULL_ENTITY" or kind == "SHOW_ENTITY"
			data = @decode_entity!
		elseif kind == "HIDE_ENTITY"
			data = @decode_hide!
		elseif kind == "TAG_CHANGE"
			data = @decode_change!
		elseif kind == "CREATE_GAME"
			data = @decode_create!
		elseif kind == "POWER_START"
			data = @decode_start!
		elseif kind == "POWER_END"
			data = @decode_end!
		elseif kind == "META_DATA"
			data = @decode_metadata!
		else
			error("bad hist.kind: #{kind_idx}")
		return { :time, :kind, :data }

	decode_entity: =>
		entity = @decode_eid!
		tags = @decode_tags(entity <= 3)
		name_index = @m.strid\decode(@coder)
		local name
		if name_index > 0
			name = @strings[name_index]
		return { :entity, :tags, :name }

	decode_eid: =>
		delta = @m.eid_delta\decode(@coder)
		eid = @last_eid + delta
		@last_eid = eid
		if eid < -1
			error("something has gone horribly wrong")
		return eid

	decode_tags: (is_special = false) =>
		tags = {}
		ntags = @m.ntag\decode(@coder)
		for i = 1,ntags
			table.insert(tags, @decode_tag(is_special))
		return tags

	decode_tag: (is_special = false) =>
		local name_value
		if is_special
			name_value = @m.special_tag\decode(@coder)
		else
			name_value = @m.tag\decode(@coder)
		name = enum_names.GameTag[name_value]
		if name == nil
			name = name_value

		local tag_value
		-- value:
		if name == "HERO_ENTITY" or name == "ENTITY_ID" or name == "ATTACKING" or name == "DEFENDING"
			delta = @m.tag_eid_delta\decode(@coder)
			tag_value = @last_tag_eid + delta
			@last_tag_eid = tag_value
		elseif name == "CONTROLLER" or name == "TEAM_ID" or name == "PLAYER_ID"
			tag_value = @m.tag_controller\decode(@coder)
		elseif name == "MAXRESOURCES" or name == "MAXHANDSIZE" or name == "STARTHANDSIZE"
			tag_value = @m.tag_10limits\decode(@coder)
		elseif name == "NEXT_STEP" or name == "STEP"
			delta = @m.tag_step_delta\decode(@coder)
			tag_value = @last_tag_step + delta
			@last_tag_step = tag_value
		elseif name == "NUM_TURNS_IN_PLAY"
			tag_value = @m.tag_turns_in_play\decode(@coder)
		elseif name == "NUM_TURNS_LEFT"
			tag_value = @m.tag_turns_left\decode(@coder)
		elseif name == "TURN"
			delta = @m.tag_turn_delta\decode(@coder)
			tag_value = @last_tag_turn + delta
			@last_tag_turn = tag_value
		elseif name == "TURN_START" -- unix timestamp
			delta = @m.tag_turn_start_delta\decode(@coder)
			tag_value = @last_turn_start + delta
			@last_turn_start = tag_value
		elseif name == "ZONE"
			tag_value = @m.tag_zone\decode(@coder)
		elseif name == "ZONE_POSITION"
			tag_value = @m.tag_zone_position\decode(@coder)
		elseif name == "FACTION"
			tag_value = @m.tag_faction\decode(@coder)
		elseif name == "RESOURCES"
			tag_value = @m.tag_resources\decode(@coder)
		elseif name == "NUM_ATTACKS_THIS_TURN"
			tag_value = @m.tag_num_attacks\decode(@coder)
		elseif name == "NUM_OPTIONS_PLAYED_THIS_TURN"
			delta = @m.tag_options_played_delta\decode(@coder)
			tag_value = @expect_tag_options_played + delta
			@expect_tag_options_played = tag_value
		elseif name == "COST"
			tag_value = @m.tag_cost\decode(@coder)
		elseif name == "PREDAMAGE" or name == "DAMAGE"
			tag_value = @m.tag_damage\decode(@coder)
		elseif name == "IGNORE_DAMAGE"
			expect = not @last_tag_ignore_damage
			local tag_bool
			if @m.tag_ignore_damage\decode(@coder)
				tag_bool = expect
			else
				tag_bool = not expect
			@last_tag_ignore_damage = tag_bool
			tag_value = if tag_bool then 1 else 0
		elseif name == "IGNORE_DAMAGE_OFF"
			expect = @last_tag_ignore_damage
			local tag_bool
			if @m.tag_ignore_damage\decode(@coder)
				tag_bool = expect
			else
				tag_bool = not expect
			tag_value = if tag_bool then 1 else 0
		elseif @is_default_bool(name)
			tag_value = @m.tag_default_bool\decode(@coder)
		elseif @is_health_atk_like(name)
			tag_value = @m.tag_atkhp\decode(@coder)
		else
			tag_value = @m.tag_default\decode(@coder)

		if name == "STEP" and tag_value == enum_values.STEP.MAIN_START
			-- beginning of turn actions phase:
			@expect_tag_options_played = 0

		return { :name, value: tag_value }

	decode_hide: =>
		entity = @decode_eid!
		zone = @m.tag_zone\decode(@coder)
		return { :entity, :zone }

	decode_change: =>
		entity = @decode_eid!
		{ :name, :value } = @decode_tag(entity <= 3)
		return { :entity, tag: name, :value }

	decode_create: =>
		id = @decode_eid!
		tags = @decode_tags(true)
		game_entity = { :id, :tags }
		players = {}
		for i = 1,2
			p = {}
			p.id = @decode_eid!
			p.gameAccountId = {
				lo: @decode_bnet_id_word!
				hi: @decode_bnet_id_word!
			}
			p.card_back = @m.tag_default\decode(@coder)
			p.entity = {
				id: @decode_eid!
				tags: @decode_tags(true)
			}
			players[i] = p
		return { :game_entity, :players }

	decode_bnet_id_word: =>
		word = 0LL
		for i=63,0
			word = bor(word, lshift(s64(@m.bnet_id\decode(@coder)), i))
		return word

	decode_start: =>
		@action_depth += 1

		type_value = @m.start_kind\decode(@coder)
		index = @m.start_index\decode(@coder)
		type_name = enum_names.PowerHistoryStartType[type_value]
		if @action_depth == 1 and type_value == enum_values.PowerHistoryStartType.PLAY
			@expect_tag_options_played += 1
		source = @decode_eid!
		delta = @m.tag_eid_delta\decode(@coder)
		target = @last_tag_eid + delta
		@last_tag_eid = target
		return { type: type_name, :index, :source, :target }

	decode_end: =>
		@action_depth -= 1
		return {}

	decode_metadata: =>
		ninfo = @m.meta_ninfo\decode(@coder)
		info = {}
		for i=1,ninfo
			info[i] = @m.meta_info\decode(@coder)
		meta_type = @m.meta_type\decode(@coder) - 1
		meta_data = @m.meta_data\decode(@coder)
		return { :info, :meta_type, :data }

return { :HistCoder }
