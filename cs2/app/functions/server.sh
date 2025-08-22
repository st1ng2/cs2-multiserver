#! /bin/bash
## vim: noet:sw=0:sts=0:ts=4

# (C) 2016-2017 Maximilian Wende <dasisdormax@mailbox.org>
#
# This file is licensed under the Apache License 2.0. For more information,
# see the LICENSE file or visit: http://www.apache.org/licenses/LICENSE-2.0




App::validateGSLT () {
	[[ $GSLT ]] && return
	debug <<< "Launching CS2 with no Game Server Login Token (GSLT) specified ..."
}


App::validateCPUAffinity () {
	[[ $CPU_AFFINITY ]] || return 0
	
	# Check if taskset is available
	if ! command -v taskset >/dev/null 2>&1; then
		error <<-EOF
			**taskset** command not found! CPU affinity cannot be set.
			Install the 'util-linux' package or remove CPU_AFFINITY setting.
		EOF
		return 1
	fi
	
	# Validate CPU affinity format
	if [[ ! $CPU_AFFINITY =~ ^[0-9]+([,-][0-9]+)*$ ]]; then
		error <<-EOF
			Invalid CPU_AFFINITY format: **$CPU_AFFINITY**
			
			Valid examples:
			  "0-3"     (cores 0 through 3)
			  "0,1,2,3" (cores 0, 1, 2, and 3)
			  "4-7"     (cores 4 through 7)
		EOF
		return 1
	fi
	
	# Get available CPU count
	local max_cpu=$(($(nproc --all) - 1))
	
	# Extract the highest CPU number from the affinity string
	local highest_cpu=$(echo "$CPU_AFFINITY" | grep -o '[0-9]\+' | sort -n | tail -1)
	
	if (( highest_cpu > max_cpu )); then
		warning <<-EOF
			CPU_AFFINITY specifies core $highest_cpu, but system only has cores 0-$max_cpu.
			This may cause the server to fail to start.
		EOF
	fi
	
	debug <<< "CPU affinity validation passed: $CPU_AFFINITY (system has $((max_cpu + 1)) cores)"
	return 0
}

App::buildLaunchCommand () {
	# Read general config
	.file "$INSTCFGDIR/server.conf"

	# Load preset (such as gamemode, maps, ...)
	PRESET="${PRESET-"$__PRESET__"}"
	if [[ $PRESET ]]; then
		.file "$CFG_DIR/presets/$PRESET.conf" \
			|| .file "$APP_DIR/presets/$PRESET.conf" \
			|| error <<< "Preset '$PRESET' not found!" \
			|| exit
	fi
	applyDefaults

	# Load GOTV settings
	.conf "$APP/cfg/$INSTANCE_SUFFIX/gotv.conf"

	######## Check GSLT ########
	::hookable App::validateGSLT
	
	######## Validate CPU Affinity ########
	App::validateCPUAffinity || return
	
	######## Check PORT ########
	local PID=$(ss -Hulpn sport = :$PORT | grep -Eo 'pid=[0-9]+')
	if [[ $PID ]]; then
		error <<-EOF
			Port **$PORT** is already in use.

			Please specify a different PORT in **$INSTCFGDIR/server.conf**.
		EOF
		return
	fi

	######## PARSE MAPS AND MAPCYCLE ########

	# Convert MAPS to array
	MAPS=( ${MAPS[*]} )
	# Workshop maps are handled in generateServerConfig

	# Generate Server and GOTV titles
	TITLE=$(title)
	TITLE=${TITLE::64}
	TAGS=$(tags)
	TV_TITLE=$(tv_title)

	(( TV_ENABLE )) || unset TV_ENABLE

	######## GENERATE SERVER CONFIG FILES ########
	App::generateServerConfig || return

	MAP=${MAP:-${MAPS[0]//\\//}}

	######## GENERATE LAUNCH COMMAND ########
	LAUNCH_ARGS=(
		-dedicated
		-console
		$USE_RCON
		${TICKRATE:+-tickrate $TICKRATE} # Likely has no effect with CS2 tickless
		-ip $IP
		-port $PORT
		${MAXPLAYERS:+-maxplayers $MAXPLAYERS}

		${WAN_IP:++net_public_adr "'$WAN_IP'"}

		${APIKEY:+-authkey $APIKEY}
		${GSLT:++sv_setsteamaccount $GSLT}

		+game_type $GAMETYPE
		+game_mode $GAMEMODE
	)

	if [[ $WORKSHOP_COLLECTION_ID ]]; then
		LAUNCH_ARGS+=(
			+map de_mirage
			+host_workshop_collection $WORKSHOP_COLLECTION_ID
		)
	elif [[ $WORKSHOP_MAP_ID ]]; then
		LAUNCH_ARGS+=(
			+map de_mirage
			+host_workshop_map $WORKSHOP_MAP_ID
		)
	else
		LAUNCH_ARGS+=(
			+mapgroup $MAPGROUP
			+map $MAP
		)
	fi

	LAUNCH_ARGS+=(
		${TV_ENABLE:+
			+tv_enable 1
			+tv_port "$TV_PORT"
			+tv_maxclients "$TV_MAXCLIENTS"
		} # GOTV Settings

		${TV_RELAY:+
			+tv_relay "$TV_RELAY"
			+tv_relaypassword "$TV_RELAYPASS"
		} # GOTV RELAY SETTINGS

		+exec autoexec.cfg
	)

	LAUNCH_DIR="$INSTANCE_DIR/game/bin/linuxsteamrt64"
	
	# Build base command
	local BASE_CMD="$(quote "./cs2" "${LAUNCH_ARGS[@]}")"
	
	# Add CPU affinity if configured
	if [[ $CPU_AFFINITY ]]; then
		LAUNCH_CMD="taskset -c $CPU_AFFINITY $BASE_CMD"
		info <<< "CPU affinity configured: cores $CPU_AFFINITY"
	else
		LAUNCH_CMD="$BASE_CMD"
	fi
	
	# Generate enhanced server start script with CPU affinity support
	cat > "$TMPDIR/server-start.sh" <<-EOF
		#! /bin/bash
		$(declare -f timestamp)
		cd "$LAUNCH_DIR"
		SERVER_LOGFILE="$LOGDIR/\$(timestamp)-server.log"
		LOG_LINK="$LOGDIR/server.log"
		rm -f "\$LOG_LINK"
		ln -s "\$SERVER_LOGFILE" "\$LOG_LINK"
		
		# Log CPU affinity information if configured
		${CPU_AFFINITY:+echo "[\$(timestamp)] Starting CS2 server with CPU affinity: $CPU_AFFINITY" | tee -a "\$SERVER_LOGFILE"}
		${CPU_AFFINITY:+echo "[\$(timestamp)] Available CPUs: \$(nproc --all)" | tee -a "\$SERVER_LOGFILE"}
		
		# Execute the server with optional CPU affinity
		stdbuf -o0 -e0 $LAUNCH_CMD 2>&1 | tee "\$SERVER_LOGFILE"
		
		exit_code=\$?
		echo "[\$(timestamp)] Server exited with code: \$exit_code" | tee -a "\$SERVER_LOGFILE"
		echo \$exit_code > "$TMPDIR/server.exit-code"
	EOF
}


# Announces an update which will cause the server to shut down
App::announceUpdate () {
	tmux-send -t ":$APP-server" <<-EOF
		say "This server is shutting down for an update soon. See you later!"
	EOF
}

# Ask the server to shut down
App::shutdownServer () {
	tmux-send -t ":$APP-server" <<-EOF
		quit
	EOF
}

App::killServer () {
	# CS2 survives a hangup of the launching terminal, so we kill the process owning the socket directly
	local PID=$(ss -Hulpn sport = :$PORT | grep -Eo 'pid=[0-9]+')
	[[ $PID ]] || return
	PID=${PID#*=}
	debug <<< "Killing server with pid = $PID ..."
	kill $PID
}