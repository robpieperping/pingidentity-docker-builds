#!/usr/bin/env sh
#
# Ping Identity DevOps - Docker Build Hooks
#
#- This hook will get bits from a git repo based on SERVER_PROFILE_* variables
#- passed to the container.  If no SERVER_PROFILES are passed, then nothing will
#- occur when running this hook.
#-
#- These bits will be placed into the STAGING_DIR location (defaults to
#- ${BASE_DIR}/staging).
#-
#- Server Profiles may be layered to copy in profils from a parent/ancestor server
#- profile.  An example might be a layer of profiles that look like:
#-
#- - Dev Environment Configs (DEV_CONFIG)
#-   - Dev Certificates (DEV_CERT)
#-     - Base Configs (BASE)
#-
#- This would result in a set of SERVER_PROFILE variables that looks like:
#- - SERVER_PROFILE_URL=...git url of DEV_CONFIG...
#- - SERVER_PROFILE_PARENT=DEV_CERT
#- - SERVER_PROFILE_DEV_CERT_URL=...git url of DEV_CERT...
#- - SERVER_PROFILE_DEV_CERT_PARENT=BASE
#- - SERVER_PROFILE_BASE_URL=...git url of BASE...
#-
#- In this example, the bits for BASE would be pulled, followed by DEV_CERT, followed
#- by DEV_CONFIG
#-
#- If other source maintenance repositories are used (i.e. bitbucket, s3, ...)
#- then this hook could be overridden by a different hook
#
${VERBOSE} && set -x

# shellcheck source=pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"


########################################################################################
# performs a git clone on the server profile passed
########################################################################################
getProfile ()
{
    serverProfileUrl=$( get_value "${1}_URL" )
    serverProfileBranch=$( get_value "${1}_BRANCH" )
    serverProfilePath=$( get_value "${1}_PATH" )

    # this is a precaution because git clone needs an empty target
    rm -rf "${SERVER_PROFILE_DIR}"
    if test -n "${serverProfileUrl}" ; then
        # deploy configuration if provided
        if test "${SERVER_PROFILE_URL_REDACT}" = "true"; then
            serverProfileUrlDisplay="*** REDACTED ***"
        else
            serverProfileUrlDisplay="${serverProfileUrl}"
        fi

        echo "Getting ${1}"
        echo "  git url: ${serverProfileUrlDisplay}"
        test -n "${serverProfileBranch}" && echo "   branch: ${serverProfileBranch}"
        test -n "${serverProfilePath}" && echo "     path: ${serverProfilePath}"

        git clone --depth 1 ${serverProfileBranch:+--branch} ${serverProfileBranch} "${serverProfileUrl}" "${SERVER_PROFILE_DIR}"
        die_on_error 141 "Git clone failure"  || exit ${?}
       
        #
        # Perform Security Checks on the Server Profile cloned
        #
        # note: this will also search paths ouside of the SERVER_PROFILE_PATH.  
        #       future enhancement may want to limit the directory checked.
        #       i.e. ${SERVER_PROFILE_DIR}/${serverProfilePath}
        #
        echo "Checking for security filename issues...${SECURITY_CHECKS_FILENAME}"

        for _scPatternCheck in ${SECURITY_CHECKS_FILENAME}; do
            security_filename_check "${SERVER_PROFILE_DIR}" "${_scPatternCheck}"
        done

        if test ${_totalSecurityViolations} -gt 0; then
            if test "${SECURITY_CHECKS_STRICT}" = "true"; then
                container_failure 2 "Security Violations Found! (total=${_totalSecurityViolations})"
            else
                echo_green "Security Violations Allowed! (total=${_totalSecurityViolations}) SECURITY_CHECKS_STRICT=${SECURITY_CHECKS_STRICT}"
            fi
        else
            echo "   PASSED"
        fi 

        # shellcheck disable=SC2086
        cp -af ${SERVER_PROFILE_DIR}/${serverProfilePath}/. "${STAGING_DIR}"
        die_on_error 142 "Copy to staging failure"  || exit ${?}
    fi    
}

########################################################################################
# takes the current server profile name and appends _PARENT to the end
#   Example: SERVER_PROFILE          returns SERVER_PROFILE_PARENT
#            SERVER_PROFILE_LICENSE  returns SERVER_PROFILE_LICENSE_PARENT
########################################################################################
getParent ()
{
    echo ${serverProfilePrefix}${serverProfileName:+_}${serverProfileName}"_PARENT"
}

########################################################################################
# main
serverProfilePrefix="SERVER_PROFILE"
serverProfileName=""
serverProfileParent=$( getParent )
serverProfileList=""

# creates a spaced separated list of server profiles starting with the parent most
# profile and moving down.
while test -n "$( get_value ${serverProfileParent} )" ; do
    # echo "Profile parent variable: ${serverProfileParent}"
    serverProfileName=$( get_value ${serverProfileParent} )
    serverProfileList="${serverProfileName}${serverProfileList:+ }${serverProfileList}"
    # echo "Profile parent value   : ${serverProfileName}"
    serverProfileParent=$( getParent )
done

# now, take that spaced separated list of servers and get the profiles for each
# one until exhausted.  
for serverProfileName in ${serverProfileList} ; do
    getProfile "${serverProfilePrefix}_${serverProfileName}"
done

#Finally after all are processed, get the final top level SERVER_PROFILE
getProfile ${serverProfilePrefix}

# GDO-200 - Try to encourage orchestration variables over env_vars
_env_vars_file="${STAGING_DIR}/env_vars"
if test -f "${_env_vars_file}"; then
    grep '.suppress-container-warning' "${_env_vars_file}" 2>/dev/null >/dev/null

    if test $? -ne 0; then
        echo ""
        echo_red "WARNING: Found an 'env_vars' file in server profile.  Variables set"
        echo_red "         in 'env_vars' may override image and orchestration variables."
        echo ""
        echo_red "         To suppress this warning in the future, include the following"
        echo_red "         string in a comment"
        echo ""
        echo_red "         # .surpress-container-warning"
    fi

    cat "${_env_vars_file}" >> "${CONTAINER_ENV}"
else
    touch "${CONTAINER_ENV}"
fi