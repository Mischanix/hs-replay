{ :enum_names, :enum_values } = require "enums"

ffi = require "ffi"

ffi.cdef[[
uint64_t strtoull(const char *str, char **str_end, int base);
]]

debug_print_id = "GameState.DebugPrintPower() - "

class LogParser
	parse: (log) =>
		@last_pos = 1
		@last_line = 1
		@pos = 1
		@buf = log\gsub("\r\n", "\n")
		@len = @buf\len!
		@time_start = -1
		@last_time = -1
		@days_passed = 0
		@hists = {}
		@names = { GameEntity: 1 }
		@pve_pid = 0

		while true
			hist = @parse_hist!
			if hist == nil
				return @hists
			table.insert(@hists, hist)
		return @hists

	parse_hist: =>
		hist_time = -1
		local kind
		data = {}
		cur_tags = {}

		while true
			@last_line = @pos
			if @pos >= @len - 2
				return nil
			if not @is_match("D ")
				@error("Input line should have `D {timestamp}` as prefix")
			@pos += 2
			@next!

			hours = tonumber(@token_until(":"))
			mins = tonumber(@token_until(":"))
			secs = tonumber(@token_until("."))
			msecs = tonumber(@token_until(" ")\sub(1, 3))

			time = (msecs / 1000) + secs
			time += mins * 60
			time += hours * (60 * 60)
			time += @days_passed * (60 * 60 * 24)
			if @time_start < 0
				@time_start = time
			elseif @last_time > time
				-- the logger has passed midnight:
				@days_passed += 1
				time += 60 * 60 * 24
			@last_time = time

			if not @is_match(debug_print_id)
				@token_until("\n")
				continue -- goto top
			if hist_time < 0
				hist_time = time
			@pos += debug_print_id\len!
			-- skip any indentation
			while @is_match(" ")
				@pos += 1
			@next!

			if kind == nil
				-- expecting a type now, then
				kind = @token_until_any(" \n")
				if kind == "ACTION_START"
					kind = "POWER_START"
				if kind == "ACTION_END"
					kind = "POWER_END"
				if enum_values.PowerHistoryKind[kind] == nil
					@error("bad history kind")
				-- otherwise, we have more stuff!
				if kind == "FULL_ENTITY"
					-- FULL_ENTITY - Creating ID=4 CardID=HERO_05
					@token_until(" ID=")
					data.entity = tonumber(@token_until(" "))
					@token_until("CardID=")
					data.name = @token_until("\n")
					data.tags = cur_tags
				elseif kind == "SHOW_ENTITY"
					-- SHOW_ENTITY - Updating Entity=[id=31 cardId= type=INVALID zone=DECK zonePos=0 player=1] CardID=CS2_188
					@token_until(" Entity=")
					if @char! == "["
						@token_until("id=")
						data.entity = tonumber(@token_until(" "))
						@token_until(" CardID=")
					else -- this is a number, for the case of SHOW_ENTITY
						data.entity = tonumber(@token_until(" CardID="))
					data.name = @token_until("\n")
					data.tags = cur_tags
				elseif kind == "HIDE_ENTITY"
					-- HIDE_ENTITY - Entity=[name=Wolfrider id=6 zone=HAND zonePos=1 cardId=CS2_124 player=1] tag=ZONE value=DECK
					@token_until("id=")
					data.entity = tonumber(@token_until(" "))
					@token_until("ZONE value=")
					data.zone = @token_until("\n")
					break
				elseif kind == "TAG_CHANGE"
					-- TAG_CHANGE Entity=Furl tag=MULLIGAN_STATE value=DEALING
					@token_until("Entity=")
					data.entity = @get_entity_id(" tag=")
					data.tag = @parse_tag!
					data.value = @parse_value!
					if data.tag == "PLAYER_ID"
						@set_player_name(data.value, data.entity)
						data.entity = @names[data.entity]
					break
				elseif kind == "CREATE_GAME"
					data.players = {}
					@names = { GameEntity: 1 }
					@pve_pid = 0
					continue
				elseif kind == "POWER_START"
					-- ACTION_START Entity=[name=Steady Shot id=5 zone=PLAY zonePos=0 cardId=DS1h_292 player=1] SubType=POWER Index=-1 Target=0
					@token_until("Entity=")
					data.source = @get_entity_id(" SubType=")
					data.type = @token_until(" Index=")
					data.index = tonumber(@token_until(" Target="))
					data.target = @get_entity_id("\n")
					break
				elseif kind == "POWER_END"
					break
				elseif kind == "META_DATA"
					-- META_DATA - Meta=META_DAMAGE Data=10 Info=1
					@token_until(" Meta=")
					data.meta_type = @token_until(" Data=")
					data.data = tonumber(@token_until(" Info="))
					data.info = { tonumber(@token_until("\n")) }
					break
				else
					@error("this shouldn't be reached")
			elseif kind == "CREATE_GAME"
				if @is_match("GameEntity")
					@token_until(" EntityID=")
					id = @token_until("\n")
					cur_tags = {}
					data.game_entity = { :id, tags: cur_tags }
				elseif @is_match("Player")
					-- Player EntityID=2 PlayerID=1 GameAccountId=[hi=144115198130930503 lo=33733237]
					@token_until(" EntityID=")
					eid = tonumber(@token_until(" PlayerID="))
					pid = tonumber(@token_until(" GameAccountId=[hi="))
					bnetid_hi = ffi.C.strtoull(@token_until(" lo="), nil, 10)
					bnetid_lo = ffi.C.strtoull(@token_until("]\n"), nil, 10)
					cur_tags = {}
					data.players[pid] =
						id: pid,
						gameAccountId: { lo: bnetid_lo, hi: bnetid_hi }
						card_back: 0 -- not present in Power.log
						entity: { id: eid, tags: cur_tags }
				elseif @is_match("tag=") -- tag
					@token_until("tag=")
					name = @parse_tag!
					value = @parse_value!
					table.insert(cur_tags, { :name, :value })
				else
					@seek(@last_line)
					break
			elseif kind == "FULL_ENTITY" or kind == "SHOW_ENTITY"
				if not @is_match("tag=")
					@seek(@last_line)
					break
				@token_until("tag=")
				name = @parse_tag!
				value = @parse_value!
				table.insert(cur_tags, { :name, :value })
			else
				@error("bad token kind")

		return { time: hist_time, :kind, :data }

	get_entity_id: (delim) =>
		if @char! == "["
			@token_until("id=")
			id = tonumber(@token_until_any(" ]"))
			@token_until(delim)
			return id
		else
			name = @token_until(delim)
			if tonumber(name) ~= nil
				return tonumber(name)
			elseif @names[name] ~= nil
				return @names[name]
			elseif @pve_pid > 0
				return @pve_pid
			else
				return name

	set_player_name: (pid, name) =>
		-- add entry
		@names[name] = 1 + pid
		-- set pve flag
		if name == "The Innkeeper"
			@pve_pid = pid
		-- find any previous entities under this name, up until the preceding
		-- CREATE_GAME:
		i = #@hists
		while @hists[i].kind ~= "CREATE_GAME" and i >= 1
			hist = @hists[i]
			if hist.data.entity == name
				hist.data.entity = 1 + pid
			i -= 1
		create = @hists[i]
		if create.kind == "CREATE_GAME"
			create.data.players[pid].entity.name = name
		return

	parse_tag: =>
		tag = @token_until(" value=")
		if tonumber(tag) ~= nil
			return tonumber(tag)
		return tag

	parse_value: =>
		value = @token_until("\n")
		if tonumber(value) ~= nil
			return tonumber(value)
		return value

	seek: (pos) =>
		@pos = pos
		@last_pos = pos
		return

	char: => @buf\sub(@pos, @pos)

	token: => @buf\sub(@last_pos, @pos - 1)

	token_until: (delim, consume_delim = true) =>
		while not @is_match(delim)
			if @char! == "\n"
				@error("don't skip newlines in token_until")
			@pos += 1
		t = @token!
		if consume_delim
			@pos += delim\len!
		@next!
		return t

	token_until_any: (chars, consume_char = true) =>
		while true
			match = false
			for i=1,chars\len!
				if @char! == chars\sub(i, i)
					match = true
					break
			if match
				break
			@pos += 1
		t = @token!
		if consume_char
			@pos += 1
		@next!
		return t

	next: =>
		@last_pos = @pos
		return

	is_match: (str) =>
		return @buf\sub(@pos, @pos + str\len! - 1) == str

	error: (msg) =>
		error(msg .. "\nstatus: pos=#{@pos}, last_line=#{@last_line}, next3=#{@buf\sub(@pos, @pos + 2)}")

return { :LogParser }
