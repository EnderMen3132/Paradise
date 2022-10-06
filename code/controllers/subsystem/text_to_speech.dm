#define TTS_TRAIT_WHISPER (1<<1)
#define TTS_TRAIT_FASTER (1<<2)

SUBSYSTEM_DEF(tts)
	name = "Text-to-Speech"
	init_order = INIT_ORDER_DEFAULT
	wait = 1 SECONDS

	var/tts_wanted = 0
	var/tts_request_failed = 0
	var/tts_request_succeeded = 0
	var/tts_reused = 0
	var/list/tts_errors = list()
	var/tts_error_raw = ""

	// Simple Moving Average RPS
	var/list/tts_rps_list = list()
	var/tts_sma_rps = 0

	// Requests per Second (RPS), only real API requests
	var/tts_rps = 0
	var/tts_rps_counter = 0

	// Total Requests per Second (TRPS), all TTS request, even reused
	var/tts_trps = 0
	var/tts_trps_counter = 0

	// Reused Requests per Second (RRPS), only reused requests
	var/tts_rrps = 0
	var/tts_rrps_counter = 0

	var/is_enabled = TRUE

	var/list/tts_replacement_list = list(\
		"Тесла" = "Тэсла",
		"тесла" = "тэсла",
		"НТ" = "Эн Тэ",
		"трейзен" = "трэйзэн",
		"СМО" = "Эс Мэ О",
		"ГП" = "Гэ Пэ",
		"РД" = "Эр Дэ",
		"ГСБ" = "Гэ Эс Бэ",
		"СРП" = "Эс Эр Пэ",
	)

	var/list/tts_seeds = list()

	var/list/tts_local_channels_by_owner = list()

/datum/controller/subsystem/tts/stat_entry(msg)
	msg += "tRPS:[tts_trps] "
	msg += "rRPS:[tts_rrps] "
	msg += "RPS:[tts_rps] "
	msg += "smaRPS:[tts_sma_rps] | "
	msg += "W:[tts_wanted] "
	msg += "F:[tts_request_failed] "
	msg += "S:[tts_request_succeeded] "
	msg += "R:[tts_reused] "
	..(msg)

/datum/controller/subsystem/tts/Initialize(start_timeofday)
	for(var/path in subtypesof(/datum/tts_seed))
		var/datum/tts_seed/seed = new path
		tts_seeds[seed.name] = seed

	is_enabled = config.tts_enabled
	if(!is_enabled)
		flags |= SS_NO_FIRE

	return ..()

/datum/controller/subsystem/tts/fire()
	tts_rps = tts_rps_counter
	tts_rps_counter = 0
	tts_trps = tts_trps_counter
	tts_trps_counter = 0
	tts_rrps = tts_rrps_counter
	tts_rrps_counter = 0

	tts_rps_list += tts_rps
	if(tts_rps_list.len > 15)
		tts_rps_list.Cut(1,2)

	var/rps_sum = 0
	for(var/rps in tts_rps_list)
		rps_sum += rps
	tts_sma_rps = round(rps_sum / tts_rps_list.len, 0.1)

/datum/controller/subsystem/tts/Recover()
	is_enabled = SStts.is_enabled
	tts_wanted = SStts.tts_wanted
	tts_request_failed = SStts.tts_request_failed
	tts_request_succeeded = SStts.tts_request_succeeded
	tts_reused = SStts.tts_reused

/datum/controller/subsystem/tts/proc/get_tts(mob/speaker, mob/listener, message, datum/tts_seed/seed = SStts.tts_seeds["Arthas"], is_local = TRUE, effect = SOUND_EFFECT_NONE, traits = TTS_TRAIT_FASTER)
	if(!is_enabled)
		return
	if(!message)
		return
	if(isnull(listener) || !listener.client || listener.stat)
		return
	if(isnull(speaker))
		return

	tts_wanted++
	tts_trps_counter++

	var/datum/tts_provider/provider = seed.provider
	if(!provider.is_enabled)
		return
	if(provider.throttle_check())
		return

	var/dirty_text = message
	var/text = sanitize_tts_input(dirty_text)

	if(traits & TTS_TRAIT_FASTER)
		text = provider.faster(text)

	if(traits & TTS_TRAIT_WHISPER)
		text = provider.whisper(text)

	var/hash = rustg_hash_string(RUSTG_HASH_MD5, lowertext(text))
	var/filename = "sound/tts_cache/[seed.name]/[hash]"

	if(fexists("[filename].ogg"))
		tts_reused++
		tts_rrps_counter++
		play_tts(speaker, listener, filename, is_local, effect)
		return

	var/datum/callback/cb = CALLBACK(src, .proc/get_tts_callback, speaker, listener, filename, seed, is_local, effect)
	provider.request(text, seed, cb)
	tts_rps_counter++

/datum/controller/subsystem/tts/proc/get_tts_callback(mob/speaker, mob/listener, filename, datum/tts_seed/seed, is_local, effect, datum/http_response/response)
	var/datum/tts_provider/provider = seed.provider

	// Bail if it errored
	if(response.errored)
		message_admins("<span class='warning'>Error connecting to [provider.name] TTS API. Please inform a maintainer or server host.</span>")
		return

	if(response.status_code != 200)
		message_admins("<span class='warning'>Error performing [provider.name] TTS API request (Code: [response.status_code])</span>")
		tts_request_failed++
		if(response.status_code)
			if(tts_errors["[response.status_code]"])
				tts_errors["[response.status_code]"]++
			else
				tts_errors += "[response.status_code]"
				tts_errors["[response.status_code]"] = 1
		tts_error_raw = response.error
		return

	tts_request_succeeded++

	var/voice = provider.process_response(response)
	if(!voice)
		return

	rustg_file_write(voice, "[filename].ogg", "true")

	if(!config.tts_cache)
		addtimer(CALLBACK(src, .proc/cleanup_tts_file, "[filename].ogg"), 30 SECONDS)

	play_tts(speaker, listener, filename, is_local, effect)

/datum/controller/subsystem/tts/proc/play_tts(mob/speaker, mob/listener, filename, is_local = TRUE, effect = SOUND_EFFECT_NONE)
	if(isnull(listener) || !listener.client || listener.stat)
		return
	if(isnull(speaker))
		return

	var/turf/turf_source = get_turf(speaker)

	var/voice
	switch(effect)
		if(SOUND_EFFECT_NONE)
			voice = "[filename].ogg"
		if(SOUND_EFFECT_RADIO)
			voice = "[filename]_radio.ogg"
			if(!fexists(voice))
				apply_sound_effect(effect, "[filename].ogg", voice)
		if(SOUND_EFFECT_ROBOT)
			voice = "[filename]_robot.ogg"
			if(!fexists(voice))
				apply_sound_effect(effect, "[filename].ogg", voice)
		if(SOUND_EFFECT_RADIO_ROBOT)
			voice = "[filename]_radio_robot.ogg"
			if(!fexists(voice))
				apply_sound_effect(effect, "[filename].ogg", voice)
		if(SOUND_EFFECT_MEGAPHONE)
			voice = "[filename]_megaphone.ogg"
			if(!fexists(voice))
				apply_sound_effect(effect, "[filename].ogg", voice)
		if(SOUND_EFFECT_MEGAPHONE_ROBOT)
			voice = "[filename]_megaphone_robot.ogg"
			if(!fexists(voice))
				apply_sound_effect(effect, "[filename].ogg", voice)
		else
			CRASH("Invalid sound effect chosen.")

	var/volume = 100
	var/channel = CHANNEL_TTS_RADIO
	if(is_local)
		volume = 100 * listener.client.prefs.get_channel_volume(CHANNEL_TTS_LOCAL)
		channel = get_local_channel_by_owner(speaker)

	var/sound/output = sound(voice)
	output.status = SOUND_STREAM

	listener.playsound_local(turf_source, output, volume, S = output, wait = TRUE, channel = channel)

/datum/controller/subsystem/tts/proc/get_local_channel_by_owner(owner)
	if(!ismob(owner))
		CRASH("Invalid channel owner given.")
	var/owner_ref = "\ref[owner]"
	var/channel = tts_local_channels_by_owner[owner_ref]
	if(isnull(channel))
		channel = SSsounds.reserve_sound_channel_datumless()
		tts_local_channels_by_owner[owner_ref] = channel
	return channel

/datum/controller/subsystem/tts/proc/cleanup_tts_file(filename)
	fdel(filename)

/datum/controller/subsystem/tts/proc/sanitize_tts_input(message)
	. = message
	. = trim_strip_html_properly(.)
	. = replace_characters(., tts_replacement_list, TRUE)
	. = rustg_latin_to_cyrillic(.)

/proc/tts_cast(mob/speaker, mob/listener, message, datum/tts_seed/seed, is_local = TRUE, effect = SOUND_EFFECT_NONE, traits = TTS_TRAIT_FASTER)
	SStts.get_tts(speaker, listener, message, seed, is_local, effect, traits)
