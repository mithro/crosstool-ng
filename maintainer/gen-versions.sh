#!/bin/bash

########################################
# Common meta-language implementation

declare -A info

debug()
{
    if [ -n "${DEBUG}" ]; then
        echo "DEBUG :: $@" >&2
    fi
}

info()
{
    if [ -z "${QUIET}" ]; then
        echo "INFO  :: $@" >&2
    fi
}

warn()
{
    echo "WARN  :: $@" >&2
}

error()
{
    echo "ERROR :: $@" >&2
    exit 1
}

find_end()
{
    local token="${1}"
    local count=1

    # Skip first line, we know it has the proper '#!' command on it
    endline=$[l + 1]
    while [ "${endline}" -le "${end}" ]; do
        case "${tlines[${endline}]}" in
            "#!${token} "*)
                count=$[count + 1]
                ;;
            "#!end-${token}")
                count=$[count - 1]
                ;;
        esac
        if [ "${count}" = 0 ]; then
            return
        fi
        endline=$[endline + 1]
    done
    error "line ${l}: '${token}' token is unpaired"
}

set_iter()
{
    local name="${1}"

    if [ "${info[iter_${name}]+set}" = "set" ]; then
        error "Iterator over '${name}' is already set up"
    fi
    shift
    debug "Setting iterator over '${name}' to '$*'"
    info[iter_${name}]="$*"
}

run_if()
{
    local cond="${1}"
    local endline

    find_end "if"
    if eval "${cond}"; then
        debug "True conditional '${cond}' at lines ${l}..${endline}"
        run_lines $[l + 1] $[endline - 1]
    else
        debug "False conditional '${cond}' at lines ${l}..${endline}"
    fi
    lnext=$[endline + 1]
    debug "Continue at line ${lnext}"
}

do_foreach()
{
    local var="${1}"
    local v saveinfo

    shift
    if [ "`type -t enter_${var}`" != "function" ]; then
        error "No parameter setup routine for iterator over '${var}'"
    fi
    for v in ${info[iter_${var}]}; do
        saveinfo=`declare -p info`
        eval "enter_${var} ${v}"
        eval "$@"
        eval "${saveinfo#declare -A }"
    done
}

run_foreach()
{
    local var="${1}"
    local endline

    if [ "${info[iter_${var}]+set}" != "set" ]; then
        error "line ${l}: iterator over '${var}' is not defined"
    fi
    find_end "foreach"
    debug "Loop over '${var}', lines ${l}..${endline}"
    do_foreach ${var} run_lines $[l + 1] $[endline - 1]
    lnext=$[endline + 1]
    debug "Continue at line ${lnext}"
}

run_lines()
{
    local start="${1}"
    local end="${2}"
    local l lnext s v

    debug "Running lines ${start}..${end}"
    l=${start}
    while [ "${l}" -le "${end}" ]; do
        lnext=$[l+1]
        s="${tlines[${l}]}"
        # Expand @@foo@@ to ${info[foo]}. First escape quotes/backslashes.
        s="${s//\\/\\\\}"
        s="${s//\$/\\\$}"
        while [ -n "${s}" ]; do
            case "${s}" in
                *@@*@@*)
                    v="${s#*@@}"
                    v="${v%%@@*}"
                    if [ "${info[${v}]+set}" != "set" ]; then
                        error "line ${l}: reference to undefined variable '${v}'"
                    fi
                    s="${s%%@@*}\${info[${v}]}${s#*@@*@@}"
                    ;;
                *@@*)
                    error "line ${l}: non-paired @@ markers"
                    ;;
                *)
                    break
                    ;;
            esac
        done

        debug "Evaluate: ${s}"
        case "${s}" in
            "#!if "*)
                run_if "${s#* }"
                ;;
            "#!foreach "*)
                run_foreach "${s#* }"
                ;;
            "#!//"*)
                # Comment, do nothing
                ;;
            "#!"*)
                error "line ${l}: unrecognized command"
                ;;
            *)
                # Not a special command
                eval "echo \"${s//\"/\\\"}\""
                ;;
        esac
        l=${lnext}
    done
}

run_template()
{
    local -a tlines
    local src="${1}"

    debug "Running template ${src}"
    mapfile -O 1 -t tlines < "${src}"
    run_lines 1 ${#tlines[@]}
}

########################################

# Where the version configs are generated
config_dir=config/versions
template=maintainer/kconfig-versions.template

declare -A pkg_forks pkg_milestones pkg_nforks
declare -a pkg_masters pkg_all

# Convert the argument to a Kconfig-style macro
kconfigize()
{
    local v="${1}"

    v=${v//[^0-9A-Za-z_]/_}
    echo "${v^^}"
}

# Helper for cmp_versions: compare an upstream/debian portion of
# a version. Returns 0 if equal, otherwise echoes "-1" or "1" and
# returns 1.
equal_versions()
{
    local v1="${1}"
    local v2="${2}"
    local p1 p2

    # Compare alternating non-numerical/numerical portions, until
    # non-equal portion is found or either string is exhausted.
    while [ -n "${v1}" -a -n "${v2}" ]; do
        # Find non-numerical portions and compare lexicographically
        p1="${v1%%[0-9]*}"
        p2="${v2%%[0-9]*}"
        v1="${v1#${p1}}"
        v2="${v2#${p2}}"
        #debug "lex [${p1}] v [${p2}]"
        if [ "${p1}" \< "${p2}" ]; then
            echo "-1"
            return 1
        elif [ "${p1}" \> "${p2}" ]; then
            echo "1"
            return 1
        fi
        #debug "rem [${v1}] v [${v2}]"
        # Find numerical portions and compare numerically
        p1="${v1%%[^0-9]*}"
        p2="${v2%%[^0-9]*}"
        v1="${v1#${p1}}"
        v2="${v2#${p2}}"
        #debug "num [${p1}] v [${p2}]"
        if [ "${p1:-0}" -lt "${p2:-0}" ]; then
            echo "-1"
            return 1
        elif [ "${p1:-0}" -gt "${p2:-0}" ]; then
            echo "1"
            return 1
        fi
        #debug "rem [${v1}] v [${v2}]"
    done
    if [ -n "${v1}" ]; then
        echo "1"
        return 1
    elif [ -n "${v2}" ]; then
        echo "-1"
        return 1
    fi
    return 0
}

# Compare two version strings, similar to sort -V. But we don't
# want to depend on GNU sort availability on the host.
# See http://www.debian.org/doc/debian-policy/ch-controlfields.html
# for description of what the version is expected to be.
# Returns "-1", "0" or "1" if first version is earlier, same or
# later than the second.
cmp_versions()
{
    local v1="${1}"
    local v2="${2}"
    local e1=0 e2=0 u1 u2 d1=0 d2=0

    # Case-insensitive comparison
    v1="${v1^^}"
    v2="${v2^^}"

    # Find if the versions contain epoch part
    case "${v1}" in
        *:*)
            e1="${v1%%:*}"
            v1="${v1#*:}"
            ;;
    esac
    case "${v2}" in
        *:*)
            e2="${v2%%:*}"
            v2="${v2#*:}"
            ;;
    esac

    # Compare epochs numerically
    if [ "${e1}" -lt "${e2}" ]; then
        echo "-1"
        return
    elif [ "${e1}" -gt "${e2}" ]; then
        echo "1"
        return
    fi

    # Find if the version contains a "debian" part.
    # v1/v2 will now contain "upstream" part.
    case "${v1}" in
        *-*)
            d1=${v1##*-}
            v1=${v1%-*}
            ;;
    esac
    case "${v2}" in
        *-*)
            d2=${v2##*-}
            v2=${v2%-*}
            ;;
    esac

    # Compare upstream
    if equal_versions "${v1}" "${v2}" && equal_versions "${d1}" "${d2}"; then
        echo "0"
    fi
}

# Sort versions, descending
sort_versions()
{
    local sorted
    local remains="$*"
    local next_remains
    local v vx found

    while [ -n "${remains}" ]; do
        #debug "Sorting [${remains}]"
        for v in ${remains}; do
            found=yes
            next_remains=
            #debug "Candidate ${v}"
            for vx in ${remains}; do
                #debug "${v} vs ${vx} :: `cmp_versions ${v} ${vx}`"
                case `cmp_versions ${v} ${vx}` in
                    1)
			    next_remains+=" ${vx}"
			    ;;
                    0)
			    ;;
                    -1)
			    found=no
			    #debug "Bad: earlier than ${vx}"
			    break
			    ;;
                esac
            done
            if [ "${found}" = "yes" ]; then
                # $v is less than all other members in next_remains
                sorted+=" ${v}"
                remains="${next_remains}"
                #debug "Good candidate ${v} sorted [${sorted}] remains [${remains}]"
                break
            fi
        done
    done
    echo "${sorted}"
}

read_file()
{
    local l

    while read l; do
        case "${l}" in
            "#"*) continue;;
            *=*) echo "info[${l%%=*}]=${l#*=}";;
            *) error "syntax error in '${1}': '${l}'"
        esac
    done < "${1}"
}

read_package_desc()
{
    read_file "packages/${1}/package.desc"
}

read_version_desc()
{
    read_file "packages/${1}/${2}/version.desc"
}

find_forks()
{
    local -A info

    eval `read_package_desc ${1}`

    if [ -n "${info[master]}" ]; then
        pkg_nforks[${info[master]}]=$[pkg_nforks[${info[master]}]+1]
        pkg_forks[${info[master]}]+=" ${1}"
    else
        pkg_nforks[${1}]=$[pkg_nforks[${1}]+1]
        pkg_forks[${1}]="${1}${pkg_forks[${1}]}"
        pkg_milestones[${1}]=`sort_versions ${info[milestones]}`
        pkg_masters+=( "${1}" )
    fi
}

check_obsolete_experimental()
{
    [ -z "${info[obsolete]}" ] && only_obsolete=
    [ -z "${info[experimental]}" ] && only_experimental=
}

enter_fork()
{
    local fork="${1}"
    local -A dflt_branch=( [git]="master" [svn]="/trunk" )
    local versions
    local only_obsolete only_experimental

    # Set defaults
    info[obsolete]=
    info[experimental]=
    info[repository]=
    info[repository_cset]=HEAD
    info[fork]=${fork}
    info[name]=${fork}

    eval `read_package_desc ${fork}`

    info[pfx]=`kconfigize ${fork}`
    info[originpfx]=`kconfigize ${info[origin]}`
    if [ -r "packages/${info[origin]}.help" ]; then
        info[originhelp]=`sed 's/^/\t  /' "packages/${info[origin]}.help"`
    else
        info[originhelp]="${info[master]} from ${info[origin]}."
    fi

    if [ -n "${info[repository]}" ]; then
        info[vcs]=${info[repository]%% *}
        info[repository_url]=${info[repository]##* }
        info[repository_dflt_branch]=${dflt_branch[${info[vcs]}]}
    fi

    versions=`cd packages/${fork} && \
        for f in */version.desc; do [ -r "${f}" ] && echo "${f%/version.desc}"; done`
    versions=`sort_versions ${versions}`

    set_iter version ${versions}
    info[all_versions]=${versions}

    # If a fork does not define any versions at all ("rolling release"), do not
    # consider it obsolete/experimental unless it is marked in the fork's
    # description.
    if [ -n "${versions}" ]; then
        only_obsolete=yes
        only_experimental=yes
        do_foreach version check_obsolete_experimental
        info[only_obsolete]=${only_obsolete}
        info[only_experimental]=${only_experimental}
    else
        info[only_obsolete]=${info[obsolete]}
        info[only_experimental]=${info[experimental]}
    fi
}

set_latest_milestone()
{
    if [ `cmp_versions ${info[ms]} ${info[ver]}` -le 0 -a -z "${milestone}" ]; then
        milestone=${info[ms_kcfg]}
    fi
}

enter_version()
{
    local -A ver_postfix=( \
        [,yes,,]=" (OBSOLETE)" \
        [,,yes,]=" (EXPERIMENTAL)" \
        [,yes,yes,]=" (OBSOLETE,EXPERIMENTAL)" )
    local version="${1}"
    local tmp milestone

    eval `read_version_desc ${info[fork]} ${version}`
    info[ver]=${version}
    info[kcfg]=`kconfigize ${version}`
    info[ver_postfix]=${ver_postfix[,${info[obsolete]},${info[experimental]},]}

    # TBD do we need "prev" version?
    tmp=" ${info[all_versions]} "
    tmp=${tmp##* ${version} }
    info[prev]=`kconfigize ${tmp%% *}`

    # Find the latest milestone preceding this version
    milestone=
    do_foreach milestone set_latest_milestone
    info[milestone]=${milestone}
}

enter_milestone()
{
    local ms="${1}"
    local tmp

    info[ms]=${ms}
    info[ms_kcfg]=`kconfigize ${ms}`

    tmp=" ${info[all_milestones]} "
    tmp=${tmp##* ${ms} }
    info[ms_prev]=`kconfigize ${tmp%% *}`
}

rm -rf "${config_dir}"
mkdir -p "${config_dir}"

pkg_all=( `cd packages && \
    ls */package.desc 2>/dev/null | \
    while read f; do [ -r "${f}" ] && echo "${f%/package.desc}"; done | \
    xargs echo` )

info "Generating package version descriptions"
debug "Packages: ${pkg_all[@]}"

# We need to group forks of the same package into the same
# config file. Discover such relationships and only iterate
# over "master" packages at the top.
for p in "${pkg_all[@]}"; do
    find_forks "${p}"
done
info "Master packages: ${pkg_masters[@]}"

# Now for each master, create its kconfig file with version
# definitions.
for p in "${pkg_masters[@]}"; do
    info "Generating '${config_dir}/${p}.in'"
    exec >"${config_dir}/${p}.in"
    # Base definitions for the whole config file
    info=( \
        [master]=${p} \
        [masterpfx]=`kconfigize ${p}` \
        [nforks]=${pkg_nforks[${p}]} \
        [all_milestones]=${pkg_milestones[${p}]} \
        )
    set_iter fork ${pkg_forks[${p}]}
    set_iter milestone ${pkg_milestones[${p}]}

    # TBD check that origins are set for all forks if there is more than one? or is it automatic because of a missing variable check?
    # TBD get rid of the "origin" completely and use just the fork name?
    run_template "${template}"
done
info "Done!"
