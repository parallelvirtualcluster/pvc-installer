#!/bin/sh

#set -e

log_wait_msg ()
{
	# Print a message and wait for enter
	if [ -x /bin/plymouth ] && plymouth --ping
	then
		plymouth message --text="$@"
		plymouth watch-keystroke | read nunya
	fi

	_log_msg "Waiting: ${@} ... \n"
}

# Override maybe_break from scripts/functions
maybe_break()
{
	if [ "${break}" = "$1" ]; then
		# Call original panic
		. /scripts/functions
		panic "Spawning shell within the initramfs"
	fi
}

# Override panic from scripts/functions
panic()
{
	for _PARAMETER in ${LIVE_BOOT_CMDLINE}
	do
		case "${_PARAMETER}" in
			panic=*)
				panic="${_PARAMETER#*panic=}"
				;;
		esac
	done

	DEB_1="\033[1;31m .''\`.  \033[0m"
	DEB_2="\033[1;31m: :'  : \033[0m"
	DEB_3="\033[1;31m\`. \`'\`  \033[0m"
	DEB_4="\033[1;31m  \`-    \033[0m"

	LIVELOG="\033[1;37m/boot.log\033[0m"
	DEBUG="\033[1;37mdebug\033[0m"

	# Reset redirections to avoid buffering
	exec 1>&6 6>&-
	exec 2>&7 7>&-
	kill ${tailpid}

	printf "\n\n"
	printf "  \033[1;37mBOOT FAILED!\033[0m\n"
	printf "\n"
	printf "  The PVC installer image failed to boot.\n\n"
	printf "The error message was:\n\n    "
	printf "  $@\n\n"

    # Reboot system
    printf "System will reboot in 30 seconds. Press any key to spawn a shell instead.\n"
    if ! read -t 30; then
        sleep 30
        reboot -f
    fi

	# Call original panic
	. /scripts/functions
    panic "$@"
}
