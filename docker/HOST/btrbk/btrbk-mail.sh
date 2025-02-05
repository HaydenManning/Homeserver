#!/bin/bash

## Wrapper script running "btrbk" and sending email with results

now=$(date +%Y%m%d)

#####  start config section  #####

# Email recipients, separated by whitespace:
mailto=default

# Email subject:
mail_subject_prefix="Obelix Backups: BTRBK"

# Add summary and/or detail (rsync/btrbk command output) to mail body.
# If both are not set, a mail is only sent on errors.
mail_summary=yes
mail_detail=yes

# List of mountpoints to be mounted/unmounted (whitespace-separated)
# mount_targets="/mnt/btr_pool /mnt/backup"
mount_targets="/mnt/drives/system /mnt/drives/data1 /mnt/drives/backup1"

# rsync declarations (repeat complete block for more declarations):
#rsync_src[example_data]="user@example.com:/data/"
#rsync_dst[example_data]="/mnt/backup/example.com/data/"
#rsync_log[example_data]="/mnt/backup/example.com/data-${now}.log"
#rsync_rsh[example_data]="ssh -i /mnt/backup/ssh_keys/id_rsa"
#rsync_opt[example_data]="-az --delete --inplace --numeric-ids --acls --xattrs"
# If set, add "rsync_dst" to "sync_fs" (see below) if rsync reports files transferred
#sync_fs_onchange[example_data]=yes

# Enabled rsync declarations (whitespace-separated list)
#rsync_enable="example_data"
#rsync_enable=

# If set, do not run btrbk if rsync reports no changes.
# If set to "quiet", do not send mail.
#skip_btrbk_if_unchanged=quiet

# Array of directories to sync(1) prior to running btrbk. This is
# useful for source subvolumes having "snapshot_create ondemand"
# configured in btrbk.conf.
#sync_fs=("/mnt/btr_data" "/mnt/btr_pool")

# btrbk command / options:
btrbk_command="run"
btrbk_opts="-c /etc/btrbk/btrbk.conf"


### Layout options:

# Prefix command output: useful when using mail clients displaying
# btrbk summary lines starting with ">>>" as quotations.
mail_cmd_block_prefix='\\u200B' # zero-width whitespace
#mail_cmd_block_prefix=". "


#####  end config section  #####


check_options()
{
    [[ -n "$btrbk_command" ]] || die "btrbk_command is not set"
    for key in $rsync_enable; do
        [[ -n "${rsync_src[$key]}" ]] || die "rsync_src is not set for \"$key\""
        [[ -n "${rsync_dst[$key]}" ]] || die "rsync_dst is not set for \"$key\""
        [[ -n "${rsync_opt[$key]}" ]] || die "rsync_opt is not set for \"$key\""
    done
}

send_mail()
{
    # assemble mail subject
    local subject="$mail_subject_prefix"
    [[ -n "$has_errors" ]] && subject+=" ERROR";
    [[ -n "$status"     ]] && subject+=" - $status";
    [[ -n "$xstatus"    ]] && subject+=" (${xstatus:2})";

    # assemble mail body
    local body=
    if [[ -n "$info" ]] && [[ -n "$has_errors" ]] || [[ "${mail_summary:-no}" = "yes" ]]; then
        body+="$info"
    fi
    if [[ -n "$detail" ]] && [[ -n "$has_errors" ]] || [[ "${mail_detail:-no}" = "yes" ]]; then
        [[ -n "$body" ]] && body+="\n\nDETAIL:\n"
        body+="$detail"
    fi

    # skip sending mail on empty body
    if [[ -z "$body" ]] && [[ -n "$has_errors" ]]; then
        body+="FATAL: something went wrong (errors present but empty mail body)\n"
    fi
    [[ -z "$body" ]] && exit 0

    # send mail
    echo -e "$body" | mail -s "$subject" $mailto
    if [[ $? -ne 0 ]]; then
        echo -e "$0: Failed to send btrbk mail to \"$mailto\", dumping mail:\n" 1>&2
        echo -e "<mail_subject>$subject</mail_subject>\n<mail_body>\n$body</mail_body>" 1>&2
    fi
}

einfo()
{
    info+="$1\n"
}

ebegin()
{
    ebtext=$1
    detail+="\n### $1\n"
}

eend()
{
    if [[ $1 -eq 0 ]]; then
        eetext=${3-success}
        detail+="\n"
    else
        has_errors=1
        eetext="ERROR (code=$1)"
        [[ -n "$2" ]] && eetext+=": $2"
        detail+="\n### $eetext\n"
    fi
    info+="$ebtext: $eetext\n"
    return $1
}

die()
{
    einfo "FATAL: ${1}, exiting"
    has_errors=1
    send_mail
    exit 1
}

run_cmd()
{
    cmd_out=$("$@" 2>&1)
    local ret=$?
    detail+="++ ${@@Q}\n"
    if [[ -n "${mail_cmd_block_prefix:-}" ]] && [[ -n "$cmd_out" ]]; then
        detail+=$(echo -n "$cmd_out" | sed "s/^/${mail_cmd_block_prefix}/")
        detail+="\n"
    else
        detail+=$cmd_out
    fi
    return $ret
}

mount_all()
{
    # mount all mountpoints listed in $mount_targets
    mounted=""
    for mountpoint in $mount_targets; do
        ebegin "Mounting $mountpoint"
        run_cmd findmnt -n $mountpoint
        if [[ $? -eq 0 ]]; then
            eend -1 "already mounted"
        else
            detail+="\n"
            run_cmd mount --target $mountpoint
            eend $? && mounted+=" $mountpoint"
        fi
    done
}

umount_mounted()
{
    for mountpoint in $mounted; do
        ebegin "Unmounting $mountpoint"
        run_cmd umount $mountpoint
        eend $?
    done
}


check_options
mount_all


#
# run rsync for all $rsync_enable
#
for key in $rsync_enable; do
    ebegin "Running rsync[$key]"
    if [[ -d "${rsync_dst[$key]}" ]]; then
        # There is no proper way to get a proper machine readable
        # output of "rsync did not touch anything at destination", so
        # we add "--info=stats2" and parse the output.
        # NOTE: This also appends the stats to the log file (rsync_log).
        # Another approach to count the files would be something like:
        # "rsync --out-format='' | wc -l"
        run_cmd rsync ${rsync_opt[$key]} \
                    --info=stats2 \
                    ${rsync_log[$key]:+--log-file="${rsync_log[$key]}"} \
                    ${rsync_rsh[$key]:+-e "${rsync_rsh[$key]}"} \
                    "${rsync_src[$key]}" \
                    "${rsync_dst[$key]}"
        exitcode=$?

        # parse stats2 (count created/deleted/transferred files)
        REGEXP=$'\n''Number of created files: ([0-9]+)'
        REGEXP+='.*'$'\n''Number of deleted files: ([0-9]+)'
        REGEXP+='.*'$'\n''Number of regular files transferred: ([0-9]+)'
        if [[ $cmd_out =~ $REGEXP ]]; then
            rsync_stats="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
            rsync_stats_long="${BASH_REMATCH[1]} created, ${BASH_REMATCH[2]} deleted, ${BASH_REMATCH[3]} transferred"
            nfiles=$(( ${BASH_REMATCH[1]} + ${BASH_REMATCH[2]} + ${BASH_REMATCH[3]} ))
        else
            rsync_stats_long="failed to parse stats, assuming files transferred"
            rsync_stats="-1/-1/-1"
            nfiles=-1
        fi

        eend $exitcode "$rsync_stats_long" "$rsync_stats_long"
        xstatus+=", rsync[$key]=$rsync_stats"

        if [[ $nfiles -ne 0 ]]; then
            # NOTE: on error, we assume files are transferred
            rsync_files_transferred=1
            [[ -n "${sync_fs_onchange[$key]}" ]] && sync_fs+=("${rsync_dst[$key]}")
        fi
    else
        eend -1 "Destination directory not found, skipping: ${rsync_dst[$key]}"
    fi
done

# honor skip_btrbk_if_unchanged (only if rsync is enabled and no files were transferred)
if [[ -n "$rsync_enable" ]] && [[ -n "$skip_btrbk_if_unchanged" ]] && [[ -z "$rsync_files_transferred" ]]; then
     einfo "No files transferred, exiting"
     status="No files transferred"
     umount_mounted
     if [[ "$skip_btrbk_if_unchanged" != "quiet" ]] || [[ -n "$has_errors" ]]; then
         send_mail
     fi
     exit 0
fi


#
# sync filesystems in sync_fs
#
if [[ ${#sync_fs[@]} -gt 0 ]]; then
    ebegin "Syncing filesystems at ${sync_fs[@]}"
    run_cmd sync -f "${sync_fs[@]}"
    eend $?
fi


#
# run btrbk
#
ebegin "Running btrbk"
run_cmd btrbk ${btrbk_opts:-} ${btrbk_command}
exitcode=$?
case $exitcode in
    0)  status=" succesfully backupped all subvolumes"
        ;;
    3)  status="Another instance of btrbk is running, no backup tasks performed!"
        ;;
    10) status="At least one backup task aborted!"
         ;;
    *)  status="btrbk failed with error code $exitcode"
        ;;
esac
eend $exitcode "$status"

umount_mounted
send_mail
