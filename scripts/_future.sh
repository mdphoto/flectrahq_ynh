ynh_check_var () {
    test -n "$1" || ynh_die "$2"
}

ynh_export () {
    local ynh_arg=""
    for var in $@;
    do
        ynh_arg=$(echo $var | awk '{print toupper($0)}')
        ynh_arg="YNH_APP_ARG_$ynh_arg"
        export $var=${!ynh_arg}
    done
}

# Save listed var in YunoHost app settings
# usage: ynh_save_args VARNAME1 [VARNAME2 [...]]
ynh_save_args () {
    for var in $@;
    do
        ynh_app_setting_set $app $var ${!var}
    done
}

ynh_sso_access () {
    ynh_app_setting_set $app unprotected_uris "/"

    if [[ $is_public -eq 0 ]]; then
        ynh_app_setting_set $app protected_uris "$1"
    fi
    sudo yunohost app ssowatconf
}
ynh_configure () {
    local TEMPLATE=$1
    local DEST=$2
    mkdir -p "$(dirname $DEST)"
    if [ -f '../manifest.json' ] ; then
        ynh_render_template "${YNH_CWD}/../conf/$TEMPLATE.j2" "$DEST"
    else
        ynh_render_template "${YNH_CWD}/../settings/conf/$TEMPLATE.j2" "$DEST"
    fi
}

ynh_configure_nginx () {
    ynh_configure nginx.conf /etc/nginx/conf.d/$domain.d/$app.conf
    sudo service nginx reload
}

# Upgrade
ynh_read_json () {
    python3 -c "import sys, json;print(json.load(open('$1'))['$2'])"
}

ynh_read_manifest () {
    if [ -f '../manifest.json' ] ; then
        ynh_read_json '../manifest.json' "$1"
    else
        ynh_read_json '../settings/manifest.json' "$1"
    fi
}


is_stretch () {
	if [ "$(ynh_get_debian_release)" == "stretch" ]
	then
		return 0
	else
		return 1
	fi
}

is_jessie () {
	if [ "$(ynh_get_debian_release)" == "jessie" ]
	then
		return 0
	else
		return 1
	fi
}

# Argument $1 is the size of the swap in MiB
ynh_add_swap () {
	# Declare an array to define the options of this helper.
	declare -Ar args_array=( [s]=size= )
	local size
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"

	local swap_max_size=$(( $size * 1024 ))

	local free_space=$(df --output=avail / | sed 1d)
	# Because we don't want to fill the disk with a swap file, divide by 2 the available space.
	local usable_space=$(( $free_space / 2 ))

	# Compare the available space with the size of the swap.
	# And set a acceptable size from the request
	if [ $usable_space -ge $swap_max_size ]
	then
		local swap_size=$swap_max_size
	elif [ $usable_space -ge $(( $swap_max_size / 2 )) ]
	then
		local swap_size=$(( $swap_max_size / 2 ))
	elif [ $usable_space -ge $(( $swap_max_size / 3 )) ]
	then
		local swap_size=$(( $swap_max_size / 3 ))
	elif [ $usable_space -ge $(( $swap_max_size / 4 )) ]
	then
		local swap_size=$(( $swap_max_size / 4 ))
	else
		echo "Not enough space left for a swap file" >&2
		local swap_size=0
	fi

	# If there's enough space for a swap, and no existing swap here
	if [ $swap_size -ne 0 ] && [ ! -e /swap ]
	then
		# Preallocate space for the swap file
		fallocate -l ${swap_size}K /swap
		chmod 0600 /swap
		# Create the swap
		mkswap /swap
		# And activate it
		swapon /swap
		# Then add an entry in fstab to load this swap at each boot.
		echo -e "/swap swap swap defaults 0 0 #Swap added by $app" >> /etc/fstab
	fi
}

ynh_del_swap () {
	# If there a swap at this place
	if [ -e /swap ]
	then
		# Clean the fstab
		sed -i "/#Swap added by $app/d" /etc/fstab
		# Desactive the swap file
		swapoff /swap
		# And remove it
		rm /swap
	fi
}

# Checks the app version to upgrade with the existing app version and returns:
# - UPGRADE_APP if the upstream app version has changed
# - UPGRADE_PACKAGE if only the YunoHost package has changed
#
## It stops the current script without error if the package is up-to-date
#
# This helper should be used to avoid an upgrade of an app, or the upstream part
# of it, when it's not needed
#
# To force an upgrade, even if the package is up to date,
# you have to set the variable YNH_FORCE_UPGRADE before.
# example: sudo YNH_FORCE_UPGRADE=1 yunohost app upgrade MyApp

# usage: ynh_check_app_version_changed
ynh_check_app_version_changed () {
  local force_upgrade=${YNH_FORCE_UPGRADE:-0}
  local package_check=${PACKAGE_CHECK_EXEC:-0}

  # By default, upstream app version has changed
  local return_value="UPGRADE_APP"

  local current_version=$(ynh_read_json "/etc/yunohost/apps/$YNH_APP_INSTANCE_NAME/manifest.json" "version" || echo 1.0)
  local current_upstream_version="${current_version/~ynh*/}"
  local update_version=$(ynh_read_manifest "version" || echo 1.0)
  local update_upstream_version="${update_version/~ynh*/}"

  if [ "$current_version" == "$update_version" ] ; then
      # Complete versions are the same
      if [ "$force_upgrade" != "0" ]
      then
        echo "Upgrade forced by YNH_FORCE_UPGRADE." >&2
        unset YNH_FORCE_UPGRADE
      elif [ "$package_check" != "0" ]
      then
        echo "Upgrade forced for package check." >&2
      else
        ynh_die "Up-to-date, nothing to do" 0
      fi
  elif [ "$current_upstream_version" == "$update_upstream_version" ] ; then
    # Upstream versions are the same, only YunoHost package versions differ
    return_value="UPGRADE_PACKAGE"
  fi
  echo $return_value
}
