#!/bin/bash
#
# Run select tests by setting ONLY, or as arguments to the script.
# Skip specific tests by setting EXCEPT.
#

set -e

ONLY=${ONLY:-"$*"}

# bug number for skipped test:
ALWAYS_EXCEPT="$SANITY_LNET_EXCEPT "
# UPDATE THE COMMENT ABOVE WITH BUG NUMBERS WHEN CHANGING ALWAYS_EXCEPT!

[ "$SLOW" = "no" ] && EXCEPT_SLOW=""

LUSTRE=${LUSTRE:-$(cd $(dirname $0)/..; echo $PWD)}

. $LUSTRE/tests/test-framework.sh
CLEANUP=${CLEANUP:-:}
SETUP=${SETUP:-:}
init_test_env "$@"
. ${CONFIG:=$LUSTRE/tests/cfg/$NAME.sh}
init_logging

build_test_filter

[[ -z $LNETCTL ]] && skip "Need lnetctl"

restore_mounts=false

if is_mounted $MOUNT || is_mounted $MOUNT2; then
	cleanupall || error "Failed cleanup prior to test execution"
	restore_mounts=true
fi

cleanup_lnet() {
	echo "Cleaning up LNet"
	lsmod | grep -q lnet &&
		$LNETCTL lnet unconfigure 2>/dev/null
	unload_modules
}

restore_modules=false
if module_loaded lnet ; then
	cleanup_lnet || error "Failed to unload modules before test execution"
	restore_modules=true
fi

cleanup_testsuite() {
	trap "" EXIT
	# Cleanup any tmp files created by the sub tests
	rm -f $TMP/sanity-lnet-*.yaml $LNET_PARAMS_FILE
	cleanup_netns
	cleanup_lnet
	if $restore_mounts; then
		setupall || error "Failed to setup Lustre after test execution"
	elif $restore_modules; then
		load_modules ||
			error "Couldn't load modules after test execution"
	fi
	return 0
}

TESTNS='test_ns'
FAKE_IF="test1pg"
FAKE_IP="10.1.2.3"
do_ns() {
	echo "ip netns exec $TESTNS $*"
	ip netns exec $TESTNS "$@"
}

setup_fakeif() {
	local netns="$1"

	local netns_arg=""
	[[ -n $netns ]] &&
		netns_arg="netns $netns"

	ip link add 'test1pl' type veth peer name $FAKE_IF $netns_arg
	ip link set 'test1pl' up
	if [[ -n $netns ]]; then
		do_ns ip addr add "${FAKE_IP}/31" dev $FAKE_IF
		do_ns ip link set $FAKE_IF up
	else
		ip addr add "${FAKE_IP}/31" dev $FAKE_IF
		ip link set $FAKE_IF up
	fi
}

cleanup_fakeif() {
	ip link show test1pl >& /dev/null && ip link del test1pl || return 0
}

setup_netns() {
	cleanup_netns

	ip netns add $TESTNS
	setup_fakeif $TESTNS
}

cleanup_netns() {
	(ip netns list | grep -q $TESTNS) && ip netns del $TESTNS
	cleanup_fakeif
}

configure_dlc() {
	echo "Loading LNet and configuring DLC"
	load_lnet || return $?
	do_lnetctl lnet configure
}

GLOBAL_YAML_FILE=$TMP/sanity-lnet-global.yaml
define_global_yaml() {
	$LNETCTL export --backup >${GLOBAL_YAML_FILE} ||
		error "Failed to export global yaml $?"
}

reinit_dlc() {
	if lsmod | grep -q lnet; then
		do_lnetctl lnet unconfigure ||
			error "lnetctl lnet unconfigure failed $?"
		do_lnetctl lnet configure ||
			error "lnetctl lnet configure failed $?"
	else
		configure_dlc || error "configure_dlc failed $?"
	fi
	define_global_yaml
}

append_global_yaml() {
	[[ ! -e ${GLOBAL_YAML_FILE} ]] &&
		error "Missing global yaml at ${GLOBAL_YAML_FILE}"

	cat ${GLOBAL_YAML_FILE} >> $TMP/sanity-lnet-$testnum-expected.yaml
}

create_base_yaml_file() {
	append_global_yaml
}

compare_yaml_files() {
	local expected="$TMP/sanity-lnet-$testnum-expected.yaml"
	local actual="$TMP/sanity-lnet-$testnum-actual.yaml"
	local rc=0
	! [[ -e $expected ]] && echo "$expected not found" && return 1
	! [[ -e $actual ]] && echo "$actual not found" && return 1
	if [ verify_yaml_available ]; then
		verify_compare_yaml $actual $expected || rc=$?
	else
		diff -upN ${actual} ${expected} || rc=$?
	fi
	echo "Expected:"
	cat $expected
	echo "Actual:"
	cat $actual
	return $rc
}

validate_nid() {
	local nid="$1"
	local net="${nid//*@/}"
	local addr="${nid//@*/}"

	local num_re='[0-9]+'
	local ip_re="[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"

	if [[ $net =~ (gni|kfi)[0-9]* ]]; then
		[[ $addr =~ ${num_re} ]] && return 0
	else
		[[ $addr =~ ${ip_re} ]] && return 0
	fi
}

validate_nids() {
	local yfile=$TMP/sanity-lnet-$testnum-actual.yaml
	local primary_nids=$(awk '/- primary nid:/{print $NF}' $yfile | xargs echo)
	local secondary_nids=$(awk '/- nid:/{print $NF}' $yfile | xargs echo)
	local gateway_nids=$(awk '/gateway:/{print $NF}' $yfile | xargs echo)

	local nid
	for nid in $primary_nids $secondary_nids; do
		validate_nid "$nid" || error "Bad NID \"${nid}\""
	done
	return 0
}

validate_peer_nids() {
	local num_peers="$1"
	local nids_per_peer="$2"

	local expect_p="$num_peers"
	# The primary nid also shows up in the list of secondary nids
	local expect_s="$(($num_peers + $(($nids_per_peer*$num_peers))))"

	local actual_p=$(grep -c -- '- primary nid:' $TMP/sanity-lnet-$testnum-actual.yaml)
	local actual_s=$(grep -c -- '- nid:' $TMP/sanity-lnet-$testnum-actual.yaml)
	if [[ $expect_p -ne $actual_p ]]; then
		compare_yaml_files
		error "Expected $expect_p but found $actual_p primary nids"
	elif [[ $expect_s -ne $actual_s ]]; then
		compare_yaml_files
		error "Expected $expect_s but found $actual_s secondary nids"
	fi
	validate_nids
}

validate_gateway_nids() {
	local expect_gw=$(grep -c -- 'gateway:' $TMP/sanity-lnet-$testnum-expected.yaml)
	local actual_gw=$(grep -c -- 'gateway:' $TMP/sanity-lnet-$testnum-actual.yaml)
	if [[ $expect_gw -ne $actual_gw ]]; then
		compare_yaml_files
		error "Expected $expect_gw gateways but found $actual_gw gateways"
	fi

	local expect_gwnids=$(awk '/gateway:/{print $NF}' $TMP/sanity-lnet-$testnum-expected.yaml |
			      xargs echo)
	local nid
	for nid in ${expect_gwnids}; do
		if ! grep -q "gateway: ${nid}" $TMP/sanity-lnet-$testnum-actual.yaml; then
			error "${nid} not configured as gateway"
		fi
	done

	validate_nids
}

cleanupall -f
setup_netns || error "setup_netns failed with $?"

# Determine the local interface(s) used for LNet
load_lnet "config_on_load=1" || error "Failed to load modules"

do_lnetctl net show
ip a

INTERFACES=( $(lnet_if_list) )

cleanup_lnet || error "Failed to cleanup LNet"

stack_trap 'cleanup_testsuite' EXIT

test_0() {
	configure_dlc || error "Failed to configure DLC rc = $?"
	define_global_yaml
	reinit_dlc || return $?
	do_lnetctl import <  ${GLOBAL_YAML_FILE} || error "Import failed $?"
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	create_base_yaml_file
	compare_yaml_files || error "Configuration changed after import"
}
run_test 0 "Export empty config, import the config, compare"

compare_peer_add() {
	local prim_nid="${1:+--prim_nid $1}"
	local nid="${2:+--nid $2}"

	local actual="$TMP/sanity-lnet-$testnum-actual.yaml"

	do_lnetctl peer add ${prim_nid} ${nid} || error "peer add failed $?"
	$LNETCTL export --backup > $actual || error "export failed $?"
	compare_yaml_files
	return $?
}

test_1() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 1.1.1.1@tcp
      Multi-Rail: True
      peer ni:
        - nid: 1.1.1.1@tcp
EOF
	append_global_yaml
	compare_peer_add "1.1.1.1@tcp"
}
run_test 1 "Add peer with single nid (tcp)"

test_2() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 2.2.2.2@o2ib
      Multi-Rail: True
      peer ni:
        - nid: 2.2.2.2@o2ib
EOF
	append_global_yaml
	compare_peer_add "2.2.2.2@o2ib"
}
run_test 2 "Add peer with single nid (o2ib)"

test_3() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 3.3.3.3@tcp
      Multi-Rail: True
      peer ni:
        - nid: 3.3.3.3@tcp
        - nid: 3.3.3.3@o2ib
EOF
	append_global_yaml
	compare_peer_add "3.3.3.3@tcp" "3.3.3.3@o2ib"
}
run_test 3 "Add peer with tcp primary o2ib secondary"

test_4() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 4.4.4.4@tcp
      Multi-Rail: True
      peer ni:
        - nid: 4.4.4.4@tcp
        - nid: 4.4.4.1@tcp
        - nid: 4.4.4.2@tcp
        - nid: 4.4.4.3@tcp
EOF
	append_global_yaml
	echo "Add peer with nidrange (tcp)"
	compare_peer_add "4.4.4.4@tcp" "4.4.4.[1-3]@tcp"

	echo "Add peer with nidrange that overlaps primary nid (tcp)"
	compare_peer_add "4.4.4.4@tcp" "4.4.4.[1-4]@tcp"
}
run_test 4 "Add peer with nidrange (tcp)"

test_5() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 5.5.5.5@o2ib
      Multi-Rail: True
      peer ni:
        - nid: 5.5.5.5@o2ib
        - nid: 5.5.5.1@o2ib
        - nid: 5.5.5.2@o2ib
        - nid: 5.5.5.3@o2ib
        - nid: 5.5.5.4@o2ib
EOF
	append_global_yaml
	echo "Add peer with nidrange (o2ib)"
	compare_peer_add "5.5.5.5@o2ib" "5.5.5.[1-4]@o2ib"

	echo "Add peer with nidranage that overlaps primary nid (o2ib)"
	compare_peer_add "5.5.5.5@o2ib" "5.5.5.[1-4]@o2ib"

	echo "Add peer with nidranage that contain , plus primary nid (o2ib)"
	compare_peer_add "5.5.5.5@o2ib" "5.5.5.[1,2,3-4]@o2ib"
}
run_test 5 "Add peer with nidrange (o2ib)"

test_6() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 6.6.6.6@tcp
      Multi-Rail: True
      peer ni:
        - nid: 6.6.6.6@tcp
        - nid: 6.6.6.0@tcp
        - nid: 6.6.6.2@tcp
        - nid: 6.6.6.4@tcp
        - nid: 6.6.7.0@tcp
        - nid: 6.6.7.2@tcp
        - nid: 6.6.7.4@tcp
        - nid: 6.6.1.0@o2ib
        - nid: 6.6.1.3@o2ib
        - nid: 6.6.1.6@o2ib
        - nid: 6.6.3.0@o2ib
        - nid: 6.6.3.3@o2ib
        - nid: 6.6.3.6@o2ib
        - nid: 6@gni
        - nid: 10@gni
        - nid: 6@kfi
        - nid: 10@kfi
EOF
	append_global_yaml

	local nid_expr="6.6.[6-7].[0-4/2]@tcp"
	nid_expr+=",6.6.[1-4/2].[0-6/3]@o2ib"
	nid_expr+=",[6-12/4]@gni"
	nid_expr+=",[6-12/4]@kfi"

	compare_peer_add "6.6.6.6@tcp" "${nid_expr}"
}
run_test 6 "Add peer with multiple nidranges"

compare_peer_del() {
	local prim_nid="${1:+--prim_nid $1}"
	local nid="${2:+--nid $2}"

	local actual="$TMP/sanity-lnet-$testnum-actual.yaml"

	do_lnetctl peer del ${prim_nid} ${nid} || error "peer del failed $?"
	$LNETCTL export --backup > $actual || error "export failed $?"
	compare_yaml_files
	return $?
}

test_7() {
	reinit_dlc || return $?
	create_base_yaml_file

	echo "Delete peer with single nid (tcp)"
	do_lnetctl peer add --prim_nid 7.7.7.7@tcp || error "Peer add failed $?"
	compare_peer_del "7.7.7.7@tcp"

	echo "Delete peer with single nid (o2ib)"
	do_lnetctl peer add --prim_nid 7.7.7.7@o2ib || error "Peer add failed $?"
	compare_peer_del "7.7.7.7@o2ib"

	echo "Delete peer that has multiple nids (tcp)"
	do_lnetctl peer add --prim_nid 7.7.7.7@tcp --nid 7.7.7.[8-12]@tcp ||
		error "Peer add failed $?"
	compare_peer_del "7.7.7.7@tcp"

	echo "Delete peer that has multiple nids (o2ib)"
	do_lnetctl peer add --prim_nid 7.7.7.7@o2ib --nid 7.7.7.[8-12]@o2ib ||
		error "Peer add failed $?"
	compare_peer_del "7.7.7.7@o2ib"

	echo "Delete peer that has both tcp and o2ib nids"
	do_lnetctl peer add --prim_nid 7.7.7.7@tcp \
		--nid 7.7.7.[9-12]@tcp,7.7.7.[13-15]@o2ib ||
		error "Peer add failed $?"
	compare_peer_del "7.7.7.7@tcp"

	echo "Delete peer with single nid (gni)"
	do_lnetctl peer add --prim_nid 7@gni || error "Peer add failed $?"
	compare_peer_del "7@gni"

	echo "Delete peer that has multiple nids (gni)"
	do_lnetctl peer add --prim_nid 7@gni --nid [8-12]@gni ||
		error "Peer add failed $?"
	compare_peer_del "7@gni"

	echo "Delete peer with single nid (kfi)"
	do_lnetctl peer add --prim_nid 7@kfi || error "Peer add failed $?"
	compare_peer_del "7@kfi"

	echo "Delete peer that has multiple nids (kfi)"
	do_lnetctl peer add --prim_nid 7@kfi --nid [8-12]@kfi ||
		error "Peer add failed $?"
	compare_peer_del "7@kfi"

	echo "Delete peer that has tcp, o2ib, gni and kfi nids"
	do_lnetctl peer add --prim_nid 7@gni \
		--nid [8-12]@gni,7.7.7.[1-4]@tcp,7.7.7.[5-9]@o2ib,[1-5]@kfi ||
		error "Peer add failed $?"
	compare_peer_del "7@gni"
}
run_test 7 "Various peer delete tests"

test_8() {
	reinit_dlc || return $?

	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 8.8.8.8@tcp
      Multi-Rail: True
      peer ni:
        - nid: 8.8.8.8@tcp
        - nid: 8.8.8.10@tcp
        - nid: 8.8.8.11@tcp
        - nid: 8.8.8.12@tcp
        - nid: 8.8.8.14@tcp
        - nid: 8.8.8.15@tcp
EOF
	append_global_yaml

	do_lnetctl peer add --prim_nid 8.8.8.8@tcp --nid 8.8.8.[10-15]@tcp ||
		error "Peer add failed $?"
	compare_peer_del "8.8.8.8@tcp" "8.8.8.13@tcp"
}
run_test 8 "Delete single secondary nid from peer (tcp)"

test_9() {
	reinit_dlc || return $?

	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 9.9.9.9@tcp
      Multi-Rail: True
      peer ni:
        - nid: 9.9.9.9@tcp
EOF
	append_global_yaml

	do_lnetctl peer add --prim_nid 9.9.9.9@tcp \
		--nid 9.9.9.[11-16]@tcp || error "Peer add failed $?"
	compare_peer_del "9.9.9.9@tcp" "9.9.9.[11-16]@tcp"
}
run_test 9 "Delete all secondary nids from peer (tcp)"

test_10() {
	reinit_dlc || return $?

	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 10.10.10.10@tcp
      Multi-Rail: True
      peer ni:
        - nid: 10.10.10.10@tcp
        - nid: 10.10.10.12@tcp
        - nid: 10.10.10.13@tcp
        - nid: 10.10.10.15@tcp
        - nid: 10.10.10.16@tcp
EOF
	append_global_yaml
	do_lnetctl peer add --prim_nid 10.10.10.10@tcp \
		--nid 10.10.10.[12-16]@tcp || error "Peer add failed $?"
	compare_peer_del "10.10.10.10@tcp" "10.10.10.14@tcp"
}
run_test 10 "Delete single secondary nid from peer (o2ib)"

test_11() {
	reinit_dlc || return $?

	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 11.11.11.11@tcp
      Multi-Rail: True
      peer ni:
        - nid: 11.11.11.11@tcp
EOF
	append_global_yaml
	do_lnetctl peer add --prim_nid 11.11.11.11@tcp \
		--nid 11.11.11.[13-17]@tcp || error "Peer add failed $?"
	compare_peer_del "11.11.11.11@tcp" "11.11.11.[13-17]@tcp"
}
run_test 11 "Delete all secondary nids from peer (o2ib)"

test_12() {
	reinit_dlc || return $?

	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 12.12.12.12@o2ib
      Multi-Rail: True
      peer ni:
        - nid: 12.12.12.12@o2ib
        - nid: 13.13.13.13@o2ib
        - nid: 14.13.13.13@o2ib
        - nid: 14.15.13.13@o2ib
        - nid: 15.17.1.5@tcp
        - nid: 15.17.1.10@tcp
        - nid: 15.17.1.20@tcp
EOF
	append_global_yaml
	do_lnetctl peer add --prim_nid 12.12.12.12@o2ib \
		--nid [13-14/1].[13-15/2].13.13@o2ib,[15-16/3].[17-19/4].[1].[5-20/5]@tcp ||
		error "Peer add failed $?"
	compare_peer_del "12.12.12.12@o2ib" "13.15.13.13@o2ib,15.17.1.15@tcp"
}
run_test 12 "Delete a secondary nid from peer (tcp and o2ib)"

test_13() {
	reinit_dlc || return $?

	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 13.13.13.13@o2ib
      Multi-Rail: True
      peer ni:
        - nid: 13.13.13.13@o2ib
EOF
	append_global_yaml
	do_lnetctl peer add --prim_nid 13.13.13.13@o2ib \
		--nid [14-15].[1-2/1].[1].[100-254/10]@tcp,14.14.[254].14@o2ib ||
		error "Peer add failed $?"
	compare_peer_del "13.13.13.13@o2ib" \
		"[14-15].[1-2/1].[1].[100-254/10]@tcp,14.14.[254].14@o2ib"
}
run_test 13 "Delete all secondary nids from peer (tcp and o2ib)"

create_nid() {
	local num="$1"
	local net="$2"

	if [[ $net =~ gni* ]] || [[ $net =~ kfi* ]]; then
		echo "${num}@${net}"
	else
		echo "${num}.${num}.${num}.${num}@${net}"
	fi
}

create_mr_peer_yaml() {
	local num_peers="$1"
	local secondary_nids="$2"
	local net="$3"

	echo "Generating peer yaml for $num_peers peers with $secondary_nids secondary nids"
	echo "peer:" >> $TMP/sanity-lnet-$testnum-expected.yaml
	local i
	local total_nids=$((num_peers + $((num_peers * secondary_nids))))
	local created=0
	local nidnum=1
	while [[ $created -lt $num_peers ]]; do
		local primary=$(create_nid ${nidnum} ${net})
	cat <<EOF >> $TMP/sanity-lnet-$testnum-expected.yaml
    - primary nid: $primary
      Multi-Rail: True
      peer ni:
        - nid: $primary
EOF
		local j
		local start=$((nidnum + 1))
		local end=$((nidnum + $secondary_nids))
		for j in $(seq ${start} ${end}); do
			local nid=$(create_nid $j ${net})
			echo "        - nid: $nid" >> $TMP/sanity-lnet-$testnum-expected.yaml
		done
		nidnum=$((end + 1))
		((created++))
	done
}

test_14() {
	reinit_dlc || return $?

	echo "Create single peer, single nid, using import"
	create_mr_peer_yaml 1 0 tcp
	do_lnetctl import < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	append_global_yaml
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	compare_yaml_files

	echo "Delete single peer using import --del"
	do_lnetctl import --del < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	rm -f $TMP/sanity-lnet-$testnum-expected.yaml
	create_base_yaml_file
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	compare_yaml_files
}
run_test 14 "import peer create/delete with single nid"

test_15() {
	reinit_dlc || return $?

	echo "Create multiple peers, single nid per peer, using import"
	create_mr_peer_yaml 5 0 o2ib
	# The ordering of nids for this use-case is non-deterministic, so we
	# we can't just diff the expected/actual output.
	do_lnetctl import < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	validate_peer_nids 5 0

	echo "Delete multiple peers, single nid per peer, using import --del"
	do_lnetctl import --del < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	rm -f $TMP/sanity-lnet-$testnum-expected.yaml
	create_base_yaml_file
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	compare_yaml_files
}
run_test 15 "import multi peer create/delete with single nid per peer"

test_16() {
	reinit_dlc || return $?

	echo "Create single peer, multiple nids, using import"
	create_mr_peer_yaml 1 5 tcp
	do_lnetctl import < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	validate_peer_nids 1 5

	echo "Delete single peer, multiple nids, using import --del"
	do_lnetctl import --del < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	rm -f $TMP/sanity-lnet-$testnum-expected.yaml
	create_base_yaml_file
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	compare_yaml_files
}
run_test 16 "import peer create/delete with multiple nids"

test_17() {
	reinit_dlc || return $?

	echo "Create multiple peers, multiple nids per peer, using import"
	create_mr_peer_yaml 5 7 o2ib
	do_lnetctl import < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	validate_peer_nids 5 7

	echo "Delete multiple peers, multiple nids per peer, using import --del"
	do_lnetctl import --del < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	rm -f $TMP/sanity-lnet-$testnum-expected.yaml
	create_base_yaml_file
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	compare_yaml_files
}
run_test 17 "import multi peer create/delete with multiple nids"

test_18a() {
	reinit_dlc || return $?

	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 1.1.1.1@tcp
      Multi-Rail: True
      peer ni:
        - nid: 1.1.1.1@tcp
        - nid: 2.2.2.2@tcp
        - nid: 4.4.4.4@tcp
        - nid: 3.3.3.3@o2ib
        - nid: 5@gni
EOF
	echo "Import peer with 5 nids"
	cat $TMP/sanity-lnet-$testnum-expected.yaml
	do_lnetctl import < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 1.1.1.1@tcp
      Multi-Rail: True
      peer ni:
        - nid: 2.2.2.2@tcp
        - nid: 3.3.3.3@o2ib
        - nid: 5@gni
EOF
	echo "Delete three of the nids"
	cat $TMP/sanity-lnet-$testnum-expected.yaml
	do_lnetctl import --del < $TMP/sanity-lnet-$testnum-expected.yaml
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 1.1.1.1@tcp
      Multi-Rail: True
      peer ni:
        - nid: 1.1.1.1@tcp
        - nid: 4.4.4.4@tcp
EOF
	echo "Check peer has expected nids remaining"
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	append_global_yaml
	compare_yaml_files
}
run_test 18a "Delete a subset of nids from a single peer using import --del"

test_18b() {
	reinit_dlc || return $?

	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 1.1.1.1@tcp
      Multi-Rail: True
      peer ni:
        - nid: 1.1.1.1@tcp
        - nid: 2.2.2.2@tcp
        - nid: 4.4.4.4@tcp
        - nid: 3.3.3.3@o2ib
        - nid: 5@gni
    - primary nid: 6.6.6.6@o2ib
      Multi-Rail: True
      peer ni:
        - nid: 6.6.6.6@o2ib
        - nid: 7.7.7.7@tcp
        - nid: 8.8.8.8@tcp
        - nid: 9.9.9.9@tcp
        - nid: 10@gni
EOF
	echo "Import two peers with 5 nids each"
	cat $TMP/sanity-lnet-$testnum-expected.yaml
	do_lnetctl import < $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Import failed $?"
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 1.1.1.1@tcp
      Multi-Rail: True
      peer ni:
        - nid: 2.2.2.2@tcp
        - nid: 3.3.3.3@o2ib
        - nid: 5@gni
    - primary nid: 6.6.6.6@o2ib
      Multi-Rail: True
      peer ni:
        - nid: 7.7.7.7@tcp
        - nid: 8.8.8.8@tcp
        - nid: 10@gni
EOF
	echo "Delete three of the nids from each peer"
	cat $TMP/sanity-lnet-$testnum-expected.yaml
	do_lnetctl import --del < $TMP/sanity-lnet-$testnum-expected.yaml
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 6.6.6.6@o2ib
      Multi-Rail: True
      peer ni:
        - nid: 6.6.6.6@o2ib
        - nid: 7.7.7.7@tcp
    - primary nid: 1.1.1.1@tcp
      Multi-Rail: True
      peer ni:
        - nid: 1.1.1.1@tcp
        - nid: 4.4.4.4@tcp
EOF
	append_global_yaml
	echo "Check peers have expected nids remaining"
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	compare_yaml_files
	validate_peer_nids 2 1
}
run_test 18b "Delete multiple nids from multiple peers using import --del"

test_19() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 19@gni
      Multi-Rail: True
      peer ni:
        - nid: 19@gni
EOF
	append_global_yaml
	compare_peer_add "19@gni"
}
run_test 19 "Add peer with single nid (gni)"

test_20() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 20@gni
      Multi-Rail: True
      peer ni:
        - nid: 20@gni
        - nid: 20.20.20.20@tcp
        - nid: 20.20.20.20@o2ib
EOF
	append_global_yaml
	compare_peer_add "20@gni" "20.20.20.20@tcp,20.20.20.20@o2ib"
}
run_test 20 "Add peer with gni primary and tcp, o2ib secondary"

test_21() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 21@gni
      Multi-Rail: True
      peer ni:
        - nid: 21@gni
        - nid: 22@gni
        - nid: 23@gni
        - nid: 24@gni
        - nid: 25@gni
EOF
	append_global_yaml
	echo "Add peer with nidrange (gni)"
	compare_peer_add "21@gni" "[22-25]@gni" || error
	echo "Add peer with nidrange that overlaps primary nid (gni)"
	compare_peer_add "21@gni" "[21-25]@gni"
}
run_test 21 "Add peer with nidrange (gni)"

test_22() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 22@gni
      Multi-Rail: True
      peer ni:
        - nid: 22@gni
        - nid: 24@gni
        - nid: 25@gni
        - nid: 27@gni
        - nid: 28@gni
        - nid: 29@gni
EOF
	append_global_yaml
	do_lnetctl peer add --prim_nid 22@gni --nid [24-29]@gni ||
		error "Peer add failed $?"
	compare_peer_del "22@gni" "26@gni"
}
run_test 22 "Delete single secondary nid from peer (gni)"

test_23() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 23@gni
      Multi-Rail: True
      peer ni:
        - nid: 23@gni
EOF
	append_global_yaml

	do_lnetctl peer add --prim_nid 23@gni --nid [25-29]@gni ||
		error "Peer add failed $?"
	compare_peer_del "23@gni" "[25-29]@gni"
}
run_test 23 "Delete all secondary nids from peer (gni)"

test_24() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 24@gni
      Multi-Rail: True
      peer ni:
        - nid: 24@gni
        - nid: 11@gni
        - nid: 13.13.13.13@o2ib
        - nid: 14.13.13.13@o2ib
        - nid: 14.15.13.13@o2ib
        - nid: 15.17.1.5@tcp
        - nid: 15.17.1.10@tcp
        - nid: 15.17.1.20@tcp
EOF
	append_global_yaml
	do_lnetctl peer add --prim_nid 24@gni \
		--nid [13-14/1].[13-15/2].13.13@o2ib,[15-16/3].[17-19/4].[1].[5-20/5]@tcp,[5-12/6]@gni ||
		error "Peer add failed $?"
	compare_peer_del "24@gni" "5@gni,13.15.13.13@o2ib,15.17.1.15@tcp"
}
run_test 24 "Delete a secondary nid from peer (tcp, o2ib and gni)"

test_25() {
	reinit_dlc || return $?
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: 25@gni
      Multi-Rail: True
      peer ni:
        - nid: 25@gni
EOF
	append_global_yaml
	do_lnetctl peer add --prim_nid 25@gni \
		--nid [26-27].[4-10/3].26.26@tcp,26.26.26.26@o2ib,[30-35]@gni ||
		error "Peer add failed $?"
	compare_peer_del "25@gni" \
		"[26-27].[4-10/3].26.26@tcp,26.26.26.26@o2ib,[30-35]@gni"
}
run_test 25 "Delete all secondary nids from peer (tcp, gni and o2ib)"

test_26() {
	reinit_dlc || return $?

	do_lnetctl peer add --prim_nid 1.1.1.1@tcp --lock_prim ||
		error "Peer add with --lock_prim option failed $?"
	local peer_state=$($LNETCTL peer show -v 4 --nid 1.1.1.1@tcp |
		awk '/peer state/ {print $NF}')
	# This relies on the following peer state definition:
	# #define LNET_PEER_LOCK_PRIMARY          BIT(20)
	if ((!("$peer_state" & (1 << 20)))); then
		error "Peer state does not have 'locked' bit set: $peer_state"
	fi
	do_lnetctl peer del --prim_nid 1.1.1.1@tcp ||
		error "Peer del failed $?"
	$LNETCTL peer show --nid 1.1.1.1@tcp | grep -q 1.1.1.1@tcp ||
		error "1.1.1.1@tcp is not listed"
	do_lnetctl peer del --prim_nid 1.1.1.1@tcp --force ||
		error "Peer del --force failed $?"
	do_lnetctl peer show --nid 1.1.1.1@tcp &&
		error "failed to delete 1.1.1.1@tcp"

	return 0
}
run_test 26 "Delete peer with primary nid locked"

test_99a() {
	reinit_dlc || return $?

	echo "Invalid prim_nid - peer add"
	do_lnetctl peer add --prim_nid foobar &&
		error "Command should have failed"

	echo "Invalid prim_nid - peer del"
	do_lnetctl peer del --prim_nid foobar &&
		error "Command should have failed"

	echo "Delete non-existing peer"
	do_lnetctl peer del --prim_nid 1.1.1.1@o2ib &&
		error "Command should have failed"

	echo "Don't provide mandatory argument for peer del"
	do_lnetctl peer del --nid 1.1.1.1@tcp &&
		error "Command should have failed"

	echo "Don't provide mandatory argument for peer add"
	do_lnetctl peer add --nid 1.1.1.1@tcp &&
		error "Command should have failed"

	echo "Don't provide mandatory arguments peer add"
	do_lnetctl peer add &&
		error "Command should have failed"

	echo "Invalid secondary nids"
	do_lnetctl peer add --prim_nid 1.1.1.1@tcp --nid foobar &&
		error "Command should have failed"

	echo "Exceed max nids per peer"
	do_lnetctl peer add --prim_nid 1.1.1.1@tcp --nid 1.1.1.[2-255]@tcp &&
		error "Command should have failed"

	echo "Invalid net type"
	do_lnetctl peer add --prim_nid 1@foo &&
		error "Command should have failed"

	echo "Invalid nid format"
	local invalid_nids="1@tcp 1@o2ib 1.1.1.1@gni"

	local nid
	for nid in ${invalid_nids}; do
		echo "Check invalid primary nid - '$nid'"
		do_lnetctl peer add --prim_nid $nid &&
			error "Command should have failed"
	done

	local invalid_strs="[2-1]@gni [a-f/x]@gni 256.256.256.256@tcp"
	invalid_strs+=" 1.1.1.1.[2-5/f]@tcp 1.]2[.3.4@o2ib"
	invalid_strs+="1.[2-4,[5-6],7-8].1.1@tcp foobar"

	local nidstr
	for nidstr in ${invalid_strs}; do
		echo "Check invalid nidstring - '$nidstr'"
		do_lnetctl peer add --prim_nid 1.1.1.1@tcp --nid $nidstr &&
			error "Command should have failed"
	done

	echo "Add non-local gateway"
	do_lnetctl route add --net tcp --gateway 1@gni &&
		error "Command should have failed"

	return 0
}
run_test 99a "Check various invalid inputs to lnetctl peer"

test_99b() {
	reinit_dlc || return $?

	create_base_yaml_file

	cat <<EOF > $TMP/sanity-lnet-$testnum-invalid.yaml
peer:
    - primary nid: 99.99.99.99@tcp
      Multi-Rail: Foobar
      peer ni:
        - nid: 99.99.99.99@tcp
EOF
	do_lnetctl import < $TMP/sanity-lnet-$testnum-invalid.yaml &&
		error "import should have failed"
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml
	compare_yaml_files
}
run_test 99b "Invalid value for Multi-Rail in yaml import"

have_interface() {
	local if="$1"
	local ip=$(ip addr show dev $if | awk '/ inet /{print $2}')
	[[ -n $ip ]]
}

add_net() {
	local net="$1"
	local if="$2"

	do_lnetctl net add --net ${net} --if ${if} ||
		error "Failed to add net ${net} on if ${if}"
}

del_net() {
	local net="$1"
	local if="$2"

	do_lnetctl net del --net ${net} --if ${if} ||
		error "Failed to del net ${net} on if ${if}"
}

compare_route_add() {
	local rnet="$1"
	local gw="$2"

	local actual="$TMP/sanity-lnet-$testnum-actual.yaml"

	do_lnetctl route add --net ${rnet} --gateway ${gw} ||
		error "route add failed $?"
	$LNETCTL export --backup > $actual ||
		error "export failed $?"
	validate_gateway_nids
	return $?
}

append_net_tunables() {
	local net=${1:-tcp}

	$LNETCTL net show -v --net ${net} | grep -v 'dev cpt' |
		awk '/^\s+tunables:$/,/^\s+CPT:/' >> $TMP/sanity-lnet-$testnum-expected.yaml
}

IF0_IP=$(ip -o -4 a s ${INTERFACES[0]} |
	 awk '{print $4}' | sed 's/\/.*//')
IF0_NET=$(awk -F. '{print $1"."$2"."$3}'<<<"${IF0_IP}")
IF0_HOSTNUM=$(awk -F. '{print $4}'<<<"${IF0_IP}")
if (((IF0_HOSTNUM + 5) > 254)); then
	GW_HOSTNUM=1
else
	GW_HOSTNUM=$((IF0_HOSTNUM + 1))
fi
GW_NID="${IF0_NET}.${GW_HOSTNUM}@${NETTYPE}"
test_100() {
	[[ ${NETTYPE} == tcp* ]] ||
		skip "Need tcp NETTYPE"
	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}"
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
net:
    - net type: ${NETTYPE}
      local NI(s):
        - interfaces:
              0: ${INTERFACES[0]}
EOF
	append_net_tunables tcp
	cat <<EOF >> $TMP/sanity-lnet-$testnum-expected.yaml
route:
    - net: tcp7
      gateway: ${GW_NID}
      hop: -1
      priority: 0
      health_sensitivity: 1
peer:
    - primary nid: ${GW_NID}
      Multi-Rail: False
      peer ni:
        - nid: ${GW_NID}
EOF
	append_global_yaml
	compare_route_add "tcp7" "${GW_NID}"
}
run_test 100 "Add route with single gw (tcp)"

test_101() {
	[[ ${NETTYPE} == tcp* ]] ||
		skip "Need tcp NETTYPE"
	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}"
	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
net:
    - net type: ${NETTYPE}
      local NI(s):
        - interfaces:
              0: ${INTERFACES[0]}
EOF
	append_net_tunables tcp

	echo "route:" >> $TMP/sanity-lnet-$testnum-expected.yaml
	for i in $(seq $GW_HOSTNUM $((GW_HOSTNUM + 4))); do
		cat <<EOF >> $TMP/sanity-lnet-$testnum-expected.yaml
    - net: tcp8
      gateway: ${IF0_NET}.${i}@tcp
      hop: -1
      priority: 0
      health_sensitivity: 1
EOF
	done

	echo "peer:" >> $TMP/sanity-lnet-$testnum-expected.yaml
	for i in $(seq $GW_HOSTNUM $((GW_HOSTNUM + 4))); do
		cat <<EOF >> $TMP/sanity-lnet-$testnum-expected.yaml
    - primary nid: ${IF0_NET}.${i}@tcp
      Multi-Rail: False
      peer ni:
        - nid: ${IF0_NET}.${i}@tcp
EOF
	done
	append_global_yaml

	local gw="${IF0_NET}.[$GW_HOSTNUM-$((GW_HOSTNUM + 4))]@tcp"

	compare_route_add "tcp8" "${gw}"
}
run_test 101 "Add route with multiple gw (tcp)"

compare_route_del() {
	local rnet="$1"
	local gw="$2"

	local actual="$TMP/sanity-lnet-$testnum-actual.yaml"

	do_lnetctl route del --net ${rnet} --gateway ${gw} ||
		error "route del failed $?"
	$LNETCTL export --backup > $actual ||
		error "export failed $?"
	validate_gateway_nids
}

generate_gw_nid() {
	local net=${1}

	if [[ ${net} =~ (tcp|o2ib)[0-9]* ]]; then
		echo "${GW_NID}"
	else
		echo "$((${testnum} % 255))@${net}"
	fi
}

test_102() {
	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}"
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-expected.yaml

	local gwnid=$(generate_gw_nid ${NETTYPE})

	do_lnetctl route add --net ${NETTYPE}2 --gateway ${gwnid} ||
		error "route add failed $?"
	compare_route_del "${NETTYPE}2" "${gwnid}"
}
run_test 102 "Delete route with single gw"

IP_NID_EXPR='103.103.103.[103-120/4]'
NUM_NID_EXPR='[103-120/4]'
test_103() {
	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}"
	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-expected.yaml

	local nid_expr

	if [[ $NETTYPE =~ (tcp|o2ib)[0-9]* ]]; then
		nid_expr="${IF0_NET}.[$GW_HOSTNUM-$((GW_HOSTNUM+5))/2]"
	else
		nid_expr="${NUM_NID_EXPR}"
	fi

	do_lnetctl route add --net ${NETTYPE}103 \
		--gateway ${nid_expr}@${NETTYPE} ||
		error "route add failed $?"
	compare_route_del "${NETTYPE}103" "${nid_expr}@${NETTYPE}"
}
run_test 103 "Delete route with multiple gw"

test_104() {
	local tyaml="$TMP/sanity-lnet-$testnum-expected.yaml"

	reinit_dlc || return $?

	# Default value is '3'
	local val=$($LNETCTL global show | awk '/response_tracking/{print $NF}')
	[[ $val -ne 3 ]] &&
		error "Expect 3 found $val"

	echo "Set < 0;  Should fail"
	do_lnetctl set response_tracking -1 &&
		error "should have failed $?"

	reinit_dlc || return $?
	cat <<EOF > $tyaml
global:
    response_tracking: -10
EOF
	do_lnetctl import < $tyaml &&
		error "should have failed $?"

	echo "Check valid values; Should succeed"
	local i
	for ((i = 0; i < 4; i++)); do
		reinit_dlc || return $?
		do_lnetctl set response_tracking $i ||
			error "should have succeeded $?"
		$LNETCTL global show | grep -q "response_tracking: $i" ||
			error "Failed to set response_tracking to $i"
		reinit_dlc || return $?
		cat <<EOF > $tyaml
global:
    response_tracking: $i
EOF
		do_lnetctl import < $tyaml ||
			error "should have succeeded $?"
		$LNETCTL global show | grep -q "response_tracking: $i" ||
			error "Failed to set response_tracking to $i"
	done

	reinit_dlc || return $?
	echo "Set > 3; Should fail"
	do_lnetctl set response_tracking 4 &&
		error "should have failed $?"

	reinit_dlc || return $?
	cat <<EOF > $tyaml
global:
    response_tracking: 10
EOF
	do_lnetctl import < $tyaml &&
		error "should have failed $?"
	return 0
}
run_test 104 "Set/check response_tracking param"

test_105() {
	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}"

	local gwnid=$(generate_gw_nid ${NETTYPE})

	do_lnetctl route add --net ${NETTYPE}105 --gateway ${gwnid} ||
		error "route add failed $?"
	do_lnetctl peer add --prim ${gwnid} &&
		error "peer add should fail"

	return 0
}
run_test 105 "Adding duplicate GW peer should fail"

test_106() {
	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}"

	local gwnid=$(generate_gw_nid ${NETTYPE})

	do_lnetctl route add --net ${NETTYPE}106 --gateway ${gwnid} ||
		error "route add failed $?"
	do_lnetctl peer del --prim ${gwnid} &&
		error "peer del should fail"

	return 0
}
run_test 106 "Deleting GW peer should fail"

test_107() {
	[[ ${NETTYPE} == tcp* ]] || skip "Need tcp NETTYPE"

	cleanup_netns || error "Failed to cleanup netns before test execution"
	cleanup_lnet || error "Failed to unload modules before test execution"

	setup_fakeif || error "Failed to add fake IF"
	have_interface "$FAKE_IF" ||
		error "Expect $FAKE_IF configured but not found"

	reinit_dlc || return $?

	add_net "tcp" "${INTERFACES[0]}" || return $?
	add_net "tcp" "$FAKE_IF" || return $?

	del_net "tcp" "$FAKE_IF" || return $?

	cleanup_fakeif
	cleanup_lnet
	setup_netns
}
run_test 107 "Deleting extra interface doesn't crash node"

test_108() {
	[[ ${NETTYPE} == tcp* ]] || skip "Need tcp NETTYPE"

	cleanup_netns || error "Failed to cleanup netns before test execution"
	cleanup_lnet || error "Failed to unload modules before test execution"

	setup_fakeif || error "Failed to add fake IF"
	have_interface "$FAKE_IF" ||
		error "Expect $FAKE_IF configured but not found"

	reinit_dlc || return $?

	add_net "tcp" "${INTERFACES[0]}" || return $?
	$LNETCTL net show > $TMP/sanity-lnet-$testnum-expected.yaml
	add_net "tcp" "$FAKE_IF" || return $?

	cat <<EOF >> $TMP/sanity-lnet-$testnum-expected.yaml
      -     nid: ${FAKE_IP}@tcp
            status: up
            interfaces:
                  0: ${FAKE_IF}
EOF
	$LNETCTL net show > $TMP/sanity-lnet-$testnum-actual.yaml
	compare_yaml_files || error "not all interfaces were setup"

	cleanup_fakeif
	cleanup_lnet
	setup_netns

	return 0
}
run_test 108 "Check Multi-Rail setup"

test_200() {
	[[ ${NETTYPE} == tcp* ]] ||
		skip "Need tcp NETTYPE"
	cleanup_lnet || exit 1
	load_lnet "networks=\"\""
	do_ns $LNETCTL lnet configure --all || exit 1
	$LNETCTL net show --net tcp | grep -q "nid: ${FAKE_IP}@tcp$"
}
run_test 200 "load lnet w/o module option, configure in a non-default namespace"

test_201() {
	[[ ${NETTYPE} == tcp* ]] ||
		skip "Need tcp NETTYPE"
	cleanup_lnet || exit 1
	load_lnet "networks=tcp($FAKE_IF)"
	do_ns $LNETCTL lnet configure --all || exit 1
	$LNETCTL net show --net tcp | grep -q "nid: ${FAKE_IP}@tcp$"
}
run_test 201 "load lnet using networks module options in a non-default namespace"

test_202() {
	[[ ${NETTYPE} == tcp* ]] ||
		skip "Need tcp NETTYPE"
	cleanup_lnet || exit 1
	load_lnet "networks=\"\" ip2nets=\"tcp0($FAKE_IF) ${FAKE_IP}\""
	do_ns $LNETCTL lnet configure --all || exit 1
	$LNETCTL net show | grep -q "nid: ${FAKE_IP}@tcp$"
}
run_test 202 "load lnet using ip2nets in a non-default namespace"


### Add the interfaces in the target namespace

test_203() {
	[[ ${NETTYPE} == tcp* ]] ||
		skip "Need tcp NETTYPE"
	cleanup_lnet || exit 1
	load_lnet
	do_lnetctl lnet configure || exit 1
	do_ns $LNETCTL net add --net tcp0 --if $FAKE_IF
}
run_test 203 "add a network using an interface in the non-default namespace"

LNET_PARAMS_FILE="$TMP/$TESTSUITE.parameters"
function save_lnet_params() {
	$LNETCTL global show | egrep -v '^global:$' |
			       sed 's/://' > $LNET_PARAMS_FILE
}

function restore_lnet_params() {
	local param value
	while read param value; do
		[[ $param == max_intf ]] && continue
		[[ $param == lnd_timeout ]] && continue
		$LNETCTL set ${param} ${value} ||
			error "Failed to restore ${param} to ${value}"
	done < $LNET_PARAMS_FILE
}

function lnet_health_pre() {
	save_lnet_params

	# Lower transaction timeout to speed up test execution
	$LNETCTL set transaction_timeout 10 ||
		error "Failed to set transaction_timeout $?"

	RETRY_PARAM=$($LNETCTL global show | awk '/retry_count/{print $NF}')
	RSND_PRE=$($LNETCTL stats show | awk '/resend_count/{print $NF}')
	LO_HVAL_PRE=$($LNETCTL net show -v 2 | awk '/health value/{print $NF}' |
		      xargs echo | sed 's/ /+/g' | bc -l)

	RMT_HVAL_PRE=$($LNETCTL peer show --nid ${RNIDS[0]} -v 2 2>/dev/null |
		       awk '/health value/{print $NF}' | xargs echo |
		       sed 's/ /+/g' | bc -l)

	# Might not have any peers so initialize to zero.
	RMT_HVAL_PRE=${RMT_HVAL_PRE:-0}

	return 0
}

function lnet_health_post() {
	RSND_POST=$($LNETCTL stats show | awk '/resend_count/{print $NF}')
	LO_HVAL_POST=$($LNETCTL net show -v 2 |
		       awk '/health value/{print $NF}' |
		       xargs echo | sed 's/ /+/g' | bc -l)

	RMT_HVAL_POST=$($LNETCTL peer show --nid ${RNIDS[0]} -v 2 2>/dev/null |
			awk '/health value/{print $NF}' | xargs echo |
			sed 's/ /+/g' | bc -l)

	# Might not have any peers so initialize to zero.
	RMT_HVAL_POST=${RMT_HVAL_POST:-0}

	${VERBOSE} &&
	echo "Pre resends: $RSND_PRE" &&
	echo "Post resends: $RSND_POST" &&
	echo "Resends delta: $((RSND_POST - RSND_PRE))" &&
	echo "Pre local health: $LO_HVAL_PRE" &&
	echo "Post local health: $LO_HVAL_POST" &&
	echo "Pre remote health: $RMT_HVAL_PRE" &&
	echo "Post remote health: $RMT_HVAL_POST"

	restore_lnet_params

	do_lnetctl peer set --health 1000 --all
	do_lnetctl net set --health 1000 --all

	return 0
}

function check_no_resends() {
	echo "Check that no resends took place"
	[[ $RSND_POST -ne $RSND_PRE ]] &&
		error "Found resends: $RSND_POST != $RSND_PRE"

	return 0
}

function check_resends() {
	local delta=$((RSND_POST - RSND_PRE))

	echo "Check that $RETRY_PARAM resends took place"
	[[ $delta -ne $RETRY_PARAM ]] &&
		error "Expected $RETRY_PARAM resends found $delta"

	return 0
}

function check_no_local_health() {
	echo "Check that local NI health is unchanged"
	[[ $LO_HVAL_POST -ne $LO_HVAL_PRE ]] &&
		error "Local health changed: $LO_HVAL_POST != $LO_HVAL_PRE"

	return 0
}

function check_local_health() {
	echo "Check that local NI health has been changed"
	[[ $LO_HVAL_POST -eq $LO_HVAL_PRE ]] &&
		error "Local health unchanged: $LO_HVAL_POST == $LO_HVAL_PRE"

	return 0
}

function check_no_remote_health() {
	echo "Check that remote NI health is unchanged"
	[[ $RMT_HVAL_POST -ne $RMT_HVAL_PRE ]] &&
		error "Remote health changed: $RMT_HVAL_POST != $RMT_HVAL_PRE"

	return 0
}

function check_remote_health() {
	echo "Check that remote NI health has been changed"
	[[ $RMT_HVAL_POST -eq $RMT_HVAL_PRE ]] &&
		error "Remote health unchanged: $RMT_HVAL_POST == $RMT_HVAL_PRE"

	return 0
}

RNODE=""
RLOADED=false
NET_DEL_ARGS=""
RNIDS=( )
LNIDS=( )
setup_health_test() {
	local need_mr=$1
	local rc=0

	[[ ${NETTYPE} == kfi* ]] && skip "kfi doesn't support drop rules"

	local rnodes=$(remote_nodes_list)
	[[ -z $rnodes ]] && skip "Need at least 1 remote node"

	cleanup_lnet || error "Failed to cleanup before test execution"

	# Loading modules should configure LNet with the appropriate
	# test-framework configuration
	load_lnet "config_on_load=1" || error "Failed to load modules"

	LNIDS=( $($LCTL list_nids | xargs echo) )

	RNODE=$(awk '{print $1}' <<<$rnodes)
	RNIDS=( $(do_node $RNODE $LCTL list_nids | xargs echo) )

	if [[ -z ${RNIDS[@]} ]]; then
		do_rpc_nodes $RNODE load_lnet "config_on_load=1"
		RLOADED=true
		RNIDS=( $(do_node $RNODE $LCTL list_nids | xargs echo) )
	fi

	[[ ${#LNIDS[@]} -lt 1 ]] &&
		error "No NIDs configured for local host $HOSTNAME"
	[[ ${#RNIDS[@]} -lt 1 ]] &&
		error "No NIDs configured for remote host $RNODE"

	# Ensure all peer NIs are local (i.e. non-routed config)
	local rnid rnet lnid lnet

	for rnid in ${RNIDS[@]}; do
		rnet=${rnid##*@}
		for lnid in ${LNIDS[@]}; do
			lnet=${lnid##*@}
			[[ ${lnet} == ${rnet} ]] &&
				break
		done
		[[ ${lnet} != ${rnet} ]] &&
			skip "Need non-routed configuration"
	done

	do_lnetctl discover ${RNIDS[0]} ||
		error "Unable to discover ${RNIDS[0]}"

	local mr=$($LNETCTL peer show --nid ${RNIDS[0]} |
		   awk '/Multi-Rail/{print $NF}')

	if ${need_mr} && [[ $mr == False ]]; then
		cleanup_health_test || return $?
		skip "Need MR peer"
	fi

	if ( ! ${need_mr} && [[ ${#RNIDS[@]} -gt 1 ]] ) ||
	   ( ! ${need_mr} && [[ ${#LNIDS[@]} -gt 1 ]] ); then
		cleanup_health_test || return $?
		skip "Need SR peer"
	fi

	if ${need_mr} && [[ ${#RNIDS[@]} -lt 2 ]]; then
		# Add a second, reachable NID to rnode.
		local net=${RNIDS[0]}

		net="${net//*@/}1"

		local if=$(do_rpc_nodes --quiet $RNODE lnet_if_list)
		[[ -z $if ]] &&
			error "Failed to determine interface for $RNODE"

		do_rpc_nodes $RNODE "$LNETCTL lnet configure"
		do_rpc_nodes $RNODE "$LNETCTL net add --net $net --if $if" ||
			rc=$?
		if [[ $rc -ne 0 ]]; then
			error "Failed to add interface to $RNODE rc=$?"
		else
			RNIDS[1]="${RNIDS[0]}1"
			NET_DEL_ARGS="--net $net --if $if"
		fi
	fi

	if ${need_mr} && [[ ${#LNIDS[@]} -lt 2 ]]; then
		local net=${LNIDS[0]}
		net="${net//*@/}1"

		do_lnetctl lnet configure &&
			do_lnetctl net add --net $net --if ${INTERFACES[0]} ||
			rc=$?
		if [[ $rc -ne 0 ]]; then
			error "Failed to add interface rc=$?"
		else
			LNIDS[1]="${LNIDS[0]}1"
		fi
	fi

	$LNETCTL net show

	$LNETCTL peer show -v 2 | egrep -e nid -e health

	$LCTL set_param debug=+net

	return 0

}

cleanup_health_test() {
	local rc=0

	if [[ -n $NET_DEL_ARGS ]]; then
		do_rpc_nodes $RNODE \
			"$LNETCTL net del $NET_DEL_ARGS" ||
			rc=$((rc + $?))
		NET_DEL_ARGS=""
	fi

	unload_modules || rc=$?

	if $RLOADED; then
		do_rpc_nodes $RNODE unload_modules_local ||
			rc=$((rc + $?))
		RLOADED=false
	fi

	[[ $rc -ne 0 ]] &&
		error "Failed cleanup"

	return $rc
}

add_health_test_drop_rules() {
	local args="-m GET -r 1 -e ${1}"
	local src dst

	for src in "${LNIDS[@]}"; do
		for dst in "${RNIDS[@]}" "${LNIDS[@]}"; do
			$LCTL net_drop_add -s $src -d $dst ${args} ||
				error "Failed to add drop rule $src $dst $args"
		done
	done
}

do_lnet_health_ping_test() {
	local hstatus="$1"

	echo "Simulate $hstatus"

	lnet_health_pre || return $?

	add_health_test_drop_rules ${hstatus}
	do_lnetctl ping ${RNIDS[0]} &&
		error "Should have failed"

	lnet_health_post

	$LCTL net_drop_del -a

	return 0
}

# See lnet/lnet/lib-msg.c:lnet_health_check()
LNET_LOCAL_RESEND_STATUSES="local_interrupt local_dropped local_aborted"
LNET_LOCAL_RESEND_STATUSES+=" local_no_route local_timeout"
LNET_LOCAL_NO_RESEND_STATUSES="local_error"
test_204() {
	setup_health_test false || return $?

	local hstatus
	for hstatus in ${LNET_LOCAL_RESEND_STATUSES} \
		       ${LNET_LOCAL_NO_RESEND_STATUSES}; do
		do_lnet_health_ping_test "${hstatus}" || return $?
		check_no_resends || return $?
		check_no_local_health || return $?
	done

	cleanup_health_test || return $?

	return 0
}
run_test 204 "Check no health or resends for single-rail local failures"

test_205() {
	(( $MDS1_VERSION >= $(version_code 2.14.58) )) ||
		skip "need at least 2.14.58"

	setup_health_test true || return $?

	local hstatus
	for hstatus in ${LNET_LOCAL_RESEND_STATUSES}; do
		do_lnet_health_ping_test "${hstatus}" || return $?
		check_resends || return $?
		check_local_health || return $?
	done

	for hstatus in ${LNET_LOCAL_NO_RESEND_STATUSES}; do
		do_lnet_health_ping_test "${hstatus}" || return $?
		check_no_resends || return $?
		check_local_health || return $?
	done

	cleanup_health_test || return $?

	return 0
}
run_test 205 "Check health and resends for multi-rail local failures"

# See lnet/lnet/lib-msg.c:lnet_health_check()
LNET_REMOTE_RESEND_STATUSES="remote_dropped"
LNET_REMOTE_NO_RESEND_STATUSES="remote_error remote_timeout"
test_206() {
	setup_health_test false || return $?

	local hstatus
	for hstatus in ${LNET_REMOTE_RESEND_STATUSES} \
		       ${LNET_REMOTE_NO_RESEND_STATUSES}; do
		do_lnet_health_ping_test "${hstatus}" || return $?
		check_no_resends || return $?
		check_no_local_health || return $?
		check_no_remote_health || return $?
	done

	cleanup_health_test || return $?

	return 0
}
run_test 206 "Check no health or resends for single-rail remote failures"

test_207() {
	(( $MDS1_VERSION >= $(version_code 2.14.58) )) ||
		skip "need at least 2.14.58"

	setup_health_test true || return $?

	local hstatus
	for hstatus in ${LNET_REMOTE_RESEND_STATUSES}; do
		do_lnet_health_ping_test "${hstatus}" || return $?
		check_resends || return $?
		check_no_local_health || return $?
		check_remote_health || return $?
		do_lnetctl peer set --health 1000 --all ||
			error "Unable to reset health rc=$?"
	done
	for hstatus in ${LNET_REMOTE_NO_RESEND_STATUSES}; do
		do_lnet_health_ping_test "${hstatus}" || return $?
		check_no_resends || return $?
		check_no_local_health || return $?
		check_remote_health || return $?
		do_lnetctl peer set --health 1000 --all ||
			error "Unable to reset health rc=$?"
	done

	cleanup_health_test || return $?

	return 0
}
run_test 207 "Check health and resends for multi-rail remote errors"

test_208_load_and_check_lnet() {
	local ip2nets="$1"
	local p_nid="$2"
	local s_nid="$3"
	local num_expected=1

	load_lnet "networks=\"\" ip2nets=\"${ip2nets_str}\""

	$LCTL net up ||
		error "Failed to load LNet with ip2nets \"${ip2nets_str}\""

	[[ -n $s_nid ]] &&
		num_expected=2

	declare -a nids
	nids=( $($LCTL list_nids) )

	[[ ${#nids[@]} -ne ${num_expected} ]] &&
		error "Expect ${num_expected} NIDs found ${#nids[@]}"

	[[ ${nids[0]} == ${p_nid} ]] ||
		error "Expect NID \"${p_nid}\" found \"${nids[0]}\""

	[[ -n $s_nid ]] && [[ ${nids[1]} != ${s_nid} ]] &&
		error "Expect second NID \"${s_nid}\" found \"${nids[1]}\""

	$LCTL net down &>/dev/null
	cleanup_lnet
}

test_208() {
	[[ ${NETTYPE} == tcp* ]] ||
		skip "Need tcp NETTYPE"

	cleanup_netns || error "Failed to cleanup netns before test execution"
	cleanup_lnet || error "Failed to unload modules before test execution"
	setup_fakeif || error "Failed to add fake IF"

	have_interface "$FAKE_IF" ||
		error "Expect $FAKE_IF configured but not found"

	local if0_ip=$(ip --oneline addr show dev ${INTERFACES[0]} |
		       awk '/inet /{print $4}' |
		       sed 's:/.*::')
	if0_ip=($(echo "${if0_ip[@]}" | tr ' ' '\n' | uniq | tr '\n' ' '))
	local ip2nets_str="tcp(${INTERFACES[0]}) $if0_ip"

	echo "Configure single NID \"$ip2nets_str\""
	test_208_load_and_check_lnet "${ip2nets_str}" "${if0_ip}@tcp"

	ip2nets_str="tcp(${INTERFACES[0]}) $if0_ip; tcp1($FAKE_IF) $FAKE_IP"
	echo "Configure two NIDs; two NETs \"$ip2nets_str\""
	test_208_load_and_check_lnet "${ip2nets_str}" "${if0_ip}@tcp" \
				     "${FAKE_IP}@tcp1"

	ip2nets_str="tcp(${INTERFACES[0]}) $if0_ip; tcp($FAKE_IF) $FAKE_IP"
	echo "Configure two NIDs; one NET \"$ip2nets_str\""
	test_208_load_and_check_lnet "${ip2nets_str}" "${if0_ip}@tcp" \
				     "${FAKE_IP}@tcp"
	local addr1=( ${if0_ip//./ } )
	local addr2=( ${FAKE_IP//./ } )
	local range="[${addr1[0]},${addr2[0]}]"

	local i
	for i in $(seq 1 3); do
		range+=".[${addr1[$i]},${addr2[$i]}]"
	done
	ip2nets_str="tcp(${INTERFACES[0]},${FAKE_IF}) ${range}"

	echo "Configured two NIDs; one NET alt syntax \"$ip2nets_str\""
	test_208_load_and_check_lnet "${ip2nets_str}" "${if0_ip}@tcp" \
				     "${FAKE_IP}@tcp"

	cleanup_fakeif

	echo "alt syntax with missing IF \"$ip2nets_str\""
	load_lnet "networks=\"\" ip2nets=\"${ip2nets_str}\""

	echo "$LCTL net up should fail"
	$LCTL net up &&
		error "LNet bring up should have failed"

	cleanup_lnet
}
run_test 208 "Test various kernel ip2nets configurations"

test_209() {
	(( $MDS1_VERSION >= $(version_code 2.14.58) )) ||
		skip "need at least 2.14.58"

	setup_health_test false || return $?

	echo "Simulate network_timeout w/SR config"
	lnet_health_pre

	add_health_test_drop_rules network_timeout

	do_lnetctl discover ${RNIDS[0]} &&
		error "Should have failed"

	lnet_health_post

	check_no_resends || return $?
	check_no_local_health || return $?
	check_no_remote_health || return $?

	cleanup_health_test || return $?

	setup_health_test true || return $?

	echo "Simulate network_timeout w/MR config"

	lnet_health_pre

	add_health_test_drop_rules network_timeout

	do_lnetctl discover ${RNIDS[0]} &&
		error "Should have failed"

	lnet_health_post

	check_no_resends || return $?
	check_local_health || return $?
	check_remote_health || return $?

	cleanup_health_test || return $?

	return 0
}
run_test 209 "Check health, but not resends, for network timeout"

check_nid_in_recovq() {
	local queue="$1"
	local nid="$2"
	local expect="$3"
	local max_wait="${4:-10}"
	local rc=0

	(($expect == 0)) &&
		echo "$queue recovery queue should be empty" ||
		echo "$queue recovery queue should have $nid"

	wait_update $HOSTNAME \
		"$LNETCTL debug recovery $queue | \
		 grep -wc \"nid-0: $nid\"" \
		"$expect" "$max_wait"
	rc=$?
	do_lnetctl debug recovery $queue
	(($rc == 0)) ||
		error "Expect $expect NIDs in recovery."

	return 0
}

# First ping is sent at time 0.
# 2nd at 0 + 2^1 = 2
# 3rd at 2 + 2^2 = 6
# 4th at 6 + 2^3 = 14
# 5th at 14 + 2^4 = 30
# e.g. after 10 seconds we would expect 3 pings to have been sent, and the
# NI will have been enqueued for the 4th ping.
# 
# If the recovery limit is 10 seconds, then after the 4th ping is sent
# we expect the peer NI to have aged out, so it will not actually be
# queued for a 5th ping.
# If max_recovery_ping_interval is set to 4 then:
#  First ping is sent at time 0
#  2nd at  0 + min(2^1, 4) = 2
#  3rd at  2 + min(2^2, 4) = 6
#  4th at  6 + min(2^3, 4) = 10
#  5th at 10 + min(2^4, 4) = 14
#  6th at 14 + min(2^5, 4) = 18
#  7th at 18 + min(2^6, 4) = 22
# e.g. after 4 seconds we would expect 2 pings to have been sent, and
# after 13 seconds we would expect 4 pings to have been sent
check_ping_count() {
	local queue="$1"
	local nid="$2"
	local expect="$3"
	local max_wait="$4"

	echo "Check ping counts:"

	local rc=0
	if [[ $queue == "ni" ]]; then
		wait_update $HOSTNAME \
			"$LNETCTL net show -v 2 | \
			 grep -e $nid -e ping_count | grep -wA1 $nid | \
			 awk '/ping_count/{print \\\$NF}'" "$expect" "$max_wait"
		rc=$?
		$LNETCTL net show -v 2 | grep -e $nid -e ping_count
	elif [[ $queue == peer_ni ]]; then
		wait_update $HOSTNAME \
			"$LNETCTL peer show -v 2 --nid $nid | \
			 grep -v primary | \
			 grep -e $nid -e ping_count | grep -wA1 $nid | \
			 awk '/ping_count/{print \\\$NF}'" "$expect" "$max_wait"
		rc=$?
		$LNETCTL peer show -v 2 --nid $nid | grep -v primary |
			grep -e $nid -e ping_count
	else
		error "Unrecognized queue \"$queue\""
		return 1
	fi

	((rc == 0)) || error "Unexpected ping count"

	return 0
}

test_210() {
	[[ ${NETTYPE} == kfi* ]] && skip "kfi doesn't support drop rules"

	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}" || return $?
	add_net "${NETTYPE}1" "${INTERFACES[0]}" || return $?

	local prim_nid=$($LCTL list_nids | head -n 1)

	do_lnetctl discover $prim_nid ||
		error "failed to discover myself"

	local default=$($LNETCTL global show |
			awk '/recovery_limit/{print $NF}')
	# Set recovery limit to 10 seconds.
	do_lnetctl set recovery_limit 10 ||
		error "failed to set recovery_limit"

	$LCTL set_param debug=+net
	$LCTL net_drop_add -s *@${NETTYPE} -d *@${NETTYPE} -m GET -r 1 -e local_error
	$LCTL net_drop_add -s *@${NETTYPE}1 -d *@${NETTYPE}1 -m GET -r 1 -e local_error
	$LCTL net_drop_add -s *@${NETTYPE} -d *@${NETTYPE} -r 1
	$LCTL net_drop_add -s *@${NETTYPE}1 -d *@${NETTYPE}1 -r 1
	do_lnetctl net set --health 0 --nid $prim_nid

	check_ping_count "ni" "$prim_nid" "2" "10"
	check_nid_in_recovq "-l" "$prim_nid" "1"

	check_ping_count "ni" "$prim_nid" "3" "10"
	check_nid_in_recovq "-l" "$prim_nid" "1"

	$LCTL net_drop_del -a

	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}" || return $?
	add_net "${NETTYPE}1" "${INTERFACES[0]}" || return $?

	local prim_nid=$($LCTL list_nids | head -n 1)

	do_lnetctl discover $prim_nid ||
		error "failed to discover myself"

	do_lnetctl set recovery_limit $default ||
		error "failed to set recovery_limit"

	default=$($LNETCTL global show |
		  awk '/max_recovery_ping_interval/{print $NF}')
	do_lnetctl set max_recovery_ping_interval 4 ||
		error "failed to set max_recovery_ping_interval"

	$LCTL set_param debug=+net
	$LCTL net_drop_add -s *@${NETTYPE} -d *@${NETTYPE} -m GET -r 1 -e local_error
	$LCTL net_drop_add -s *@${NETTYPE}1 -d *@${NETTYPE}1 -m GET -r 1 -e local_error
	$LCTL net_drop_add -s *@${NETTYPE} -d *@${NETTYPE} -r 1
	$LCTL net_drop_add -s *@${NETTYPE}1 -d *@${NETTYPE}1 -r 1
	do_lnetctl net set --health 0 --nid $prim_nid

	check_ping_count "ni" "$prim_nid" "2" "10"
	check_nid_in_recovq "-l" "$prim_nid" "1"

	check_ping_count "ni" "$prim_nid" "4" "10"
	check_nid_in_recovq "-l" "$prim_nid" "1"

	$LCTL net_drop_del -a

	do_lnetctl set max_recovery_ping_interval $default ||
		error "failed to set max_recovery_ping_interval"

	return 0
}
run_test 210 "Local NI recovery checks"

test_211() {
	[[ ${NETTYPE} == kfi* ]] && skip "kfi doesn't support drop rules"

	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}" || return $?
	add_net "${NETTYPE}1" "${INTERFACES[0]}" || return $?

	local prim_nid=$($LCTL list_nids | head -n 1)

	do_lnetctl discover $prim_nid ||
		error "failed to discover myself"

	local default=$($LNETCTL global show |
			awk '/recovery_limit/{print $NF}')
	# Set recovery limit to 10 seconds.
	do_lnetctl set recovery_limit 10 ||
		error "failed to set recovery_limit"

	$LCTL net_drop_add -s *@${NETTYPE} -d *@${NETTYPE} -m GET -r 1 -e remote_error
	$LCTL net_drop_add -s *@${NETTYPE}1 -d *@${NETTYPE}1 -m GET -r 1 -e remote_error
	$LCTL net_drop_add -s *@${NETTYPE} -d *@${NETTYPE} -r 1
	$LCTL net_drop_add -s *@${NETTYPE}1 -d *@${NETTYPE}1 -r 1

	# Set health to 0 on one interface. This forces it onto the recovery
	# queue.
	do_lnetctl peer set --nid $prim_nid --health 0

	check_nid_in_recovq "-p" "$prim_nid" "1"

	# The peer should age out in 10-20 seconds
	check_nid_in_recovq "-p" "$prim_nid" "0" "20"
	# Ping count should reset to 0 when peer ages out
	check_ping_count "peer_ni" "$prim_nid" "0"

	$LCTL net_drop_del -a

	# Set health to force it back onto the recovery queue. Set to 500 means
	# in ~5 seconds it should be back at maximum value.
	# NB: we reset the recovery limit to 0 (indefinite) so the peer NI is
	# eligible again
	do_lnetctl set recovery_limit 0 ||
		error "failed to set recovery_limit"

	do_lnetctl peer set --nid $prim_nid --health 500

	check_nid_in_recovq "-p" "$prim_nid" "1"
	check_nid_in_recovq "-p" "$prim_nid" "0" "20"

	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}" || return $?
	add_net "${NETTYPE}1" "${INTERFACES[0]}" || return $?

	local prim_nid=$($LCTL list_nids | head -n 1)

	do_lnetctl discover $prim_nid ||
		error "failed to discover myself"

	do_lnetctl set recovery_limit $default ||
		error "failed to set recovery_limit"

	default=$($LNETCTL global show |
		  awk '/max_recovery_ping_interval/{print $NF}')
	do_lnetctl set max_recovery_ping_interval 4 ||
		error "failed to set max_recovery_ping_interval"

	$LCTL net_drop_add -s *@${NETTYPE} -d *@${NETTYPE} -m GET -r 1 -e remote_error
	$LCTL net_drop_add -s *@${NETTYPE}1 -d *@${NETTYPE}1 -m GET -r 1 -e remote_error
	$LCTL net_drop_add -s *@${NETTYPE} -d *@${NETTYPE} -r 1
	$LCTL net_drop_add -s *@${NETTYPE}1 -d *@${NETTYPE}1 -r 1

	# Set health to 0 on one interface. This forces it onto the recovery
	# queue.
	do_lnetctl peer set --nid $prim_nid --health 0

	check_ping_count "peer_ni" "$prim_nid" "1" "4"
	check_nid_in_recovq "-p" "$prim_nid" "1"

	# After we detect the 1st ping above, the 4th ping should be sent after
	# ~13 seconds
	check_ping_count "peer_ni" "$prim_nid" "4" "14"
	check_nid_in_recovq "-p" "$prim_nid" "1"

	$LCTL net_drop_del -a

	do_lnetctl set max_recovery_ping_interval $default ||
		error "failed to set max_recovery_ping_interval"

	return 0
}
run_test 211 "Remote NI recovery checks"

test_212() {
	[[ ${NETTYPE} == kfi* ]] && skip "kfi doesn't support drop rules"

	local rnodes=$(remote_nodes_list)
	[[ -z $rnodes ]] && skip "Need at least 1 remote node"

	cleanup_lnet || error "Failed to cleanup before test execution"

	# Loading modules should configure LNet with the appropriate
	# test-framework configuration
	load_lnet "config_on_load=1" || error "Failed to load modules"

	local my_nid=$($LCTL list_nids | head -n 1)
	[[ -z $my_nid ]] &&
		error "Failed to get primary NID for local host $HOSTNAME"

	local rnode=$(awk '{print $1}' <<<$rnodes)
	local rnodenids=$(do_node $rnode $LCTL list_nids | xargs echo)
	local rloaded=false

	if [[ -z $rnodenids ]]; then
		do_rpc_nodes $rnode load_lnet "config_on_load=1"
		rloaded=true
		rnodenids=$(do_node $rnode $LCTL list_nids | xargs echo)
	fi

	local rnodepnid=$(awk '{print $1}' <<< $rnodenids)

	[[ -z $rnodepnid ]] &&
		error "Failed to get primary NID for remote host $rnode"

	log "Initial discovery"
	do_lnetctl discover --force $rnodepnid ||
		error "Failed to discover $rnodepnid"

	do_node $rnode "$LNETCTL discover --force $my_nid" ||
		error "$rnode failed to discover $my_nid"

	log "Fail local discover ping to set LNET_PEER_REDISCOVER flag"
	$LCTL net_drop_add -s "*@$NETTYPE" -d "*@$NETTYPE" -r 1 -e local_error
	do_lnetctl discover --force $rnodepnid &&
		error "Discovery should have failed"
	$LCTL net_drop_del -a

	local nid
	for nid in $rnodenids; do
		# We need GET (PING) delay just long enough so we can trigger
		# discovery on the remote peer
		$LCTL net_delay_add -s "*@$NETTYPE" -d $nid -r 1 -m GET -l 3
		$LCTL net_drop_add -s "*@$NETTYPE" -d $nid -r 1 -m GET -e local_error
		# We need PUT (PUSH) delay just long enough so we can process
		# the PING failure
		$LCTL net_delay_add -s "*@$NETTYPE" -d $nid -r 1 -m PUT -l 6
	done

	log "Force $HOSTNAME to discover $rnodepnid (in background)"
	# We want to get a PING sent that we know will eventually fail.
	# The delay rules we added will ensure the ping is not sent until
	# the PUSH is also in flight (see below), and the drop rule ensures that
	# when the PING is eventually sent it will error out
	do_lnetctl discover --force $rnodepnid &
	local pid1=$!

	# We want a discovery PUSH from rnode to put rnode back on our
	# discovery queue. This should cause us to try and send a PUSH to rnode
	# while the PING is still outstanding.
	log "Force $rnode to discover $my_nid"
	do_node $rnode $LNETCTL discover --force $my_nid

	# At this point we'll have both PING_SENT and PUSH_SENT set for the
	# rnode peer. Wait for the PING to error out which should terminate the
	# discovery process that we backgrounded.
	log "Wait for $pid1"
	wait $pid1
	log "Finished wait on $pid1"

	# The PING send failure clears the PING_SENT flag and puts the peer back
	# on the discovery queue. When discovery thread processes the peer it
	# will mistakenly clear the PUSH_SENT flag (and set PUSH_FAILED).
	# Discovery will then complete for this peer even though we have an
	# outstanding PUSH.
	# When PUSH is actually unlinked it will be forced back onto the
	# discovery queue, but we no longer have a ref on the peer. When
	# discovery completes again, we'll trip the ASSERT in
	# lnet_destroy_peer_locked()

	# Delete the delay rules to send the PUSH
	$LCTL net_delay_del -a
	# Delete the drop rules
	$LCTL net_drop_del -a

	unload_modules ||
		error "Failed to unload modules"
	if $rloaded; then
		do_rpc_nodes $rnode unload_modules_local ||
			error "Failed to unload modules on $rnode"
	fi

	return 0
}
run_test 212 "Check discovery refcount loss bug (LU-14627)"

test_213() {
	[[ ${NETTYPE} == tcp* ]] || skip "Need tcp NETTYPE"

	cleanup_netns || error "Failed to cleanup netns before test execution"
	cleanup_lnet || error "Failed to unload modules before test execution"

	setup_fakeif || error "Failed to add fake IF"
	have_interface "$FAKE_IF" ||
		error "Expect $FAKE_IF configured but not found"

	reinit_dlc || return $?

	add_net "tcp" "${INTERFACES[0]}" || return $?
	add_net "tcp" "$FAKE_IF" || return $?

	local nid1=$(lctl list_nids | head -n 1)
	local nid2=$(lctl list_nids | tail --lines 1)

	[[ $(lctl which_nid $nid1 $nid2) == $nid1 ]] ||
		error "Expect nid1 \"$nid1\" to be preferred"

	[[ $(lctl which_nid $nid2 $nid1) == $nid2 ]] ||
		error "Expect nid2 \"$nid2\" to be preferred"

	return 0
}
run_test 213 "Check LNetDist calculation for multiple local NIDs"

function check_ni_status() {
	local nid="$1"
	local expect="$2"

	local status=$($LNETCTL net show |
		       grep -A 1 ${nid} |
		       awk '/status/{print $NF}')

	echo "NI ${nid} expect status \"${expect}\" found \"${status}\""
	if [[ $status != $expect ]]; then
		error "Error: Expect NI status \"$expect\" for NID \"$nid\" but found \"$status\""
	fi

	return 0
}

test_214() {
	[[ ${NETTYPE} == tcp* ]] || skip "Need tcp NETTYPE"

	cleanup_netns || error "Failed to cleanup netns before test execution"
	cleanup_lnet || error "Failed to unload modules before test execution"

	setup_fakeif || error "Failed to add fake IF"
	have_interface "$FAKE_IF" ||
		error "Expect $FAKE_IF configured but not found"

	reinit_dlc || return $?

	add_net "tcp" "${INTERFACES[0]}" || return $?
	add_net "tcp" "$FAKE_IF" || return $?

	local nid1=$(lctl list_nids | head -n 1)
	local nid2=$(lctl list_nids | tail --lines 1)

	check_ni_status "0@lo" up
	check_ni_status "$nid1" up
	check_ni_status "$nid2" up

	do_lnetctl ping --source $nid2 $nid1 ||
		error "$LNETCTL ping --source $nid2 $nid1 failed"

	echo "Set $FAKE_IF down"
	echo "ip link set dev $FAKE_IF down"
	ip link set dev $FAKE_IF down
	check_ni_status "0@lo" up
	check_ni_status "$nid1" up
	check_ni_status "$nid2" down
}
run_test 214 "Check local NI status when link is downed"

get_ni_stat() {
	local nid=$1
	local stat=$2

	$LNETCTL net show -v 2 |
		egrep -e nid -e $stat |
		grep -wA 1 $nid |
		awk '/'$stat':/{print $NF}'
}

ni_stats_pre() {
	local nidvar s
	for nidvar in nid1 nid2; do
		for stat in send_count recv_count; do
			s=$(get_ni_stat ${!nidvar} $stat)
			eval ${nidvar}_pre_${stat}=$s
		done
	done
}

ni_stats_post() {
	local nidvar s
	for nidvar in nid1 nid2; do
		for stat in send_count recv_count; do
			s=$(get_ni_stat ${!nidvar} $stat)
			eval ${nidvar}_post_${stat}=$s
		done
	done
}

ni_stat_changed() {
	local nidvar=$1
	local stat=$2

	local pre post
	eval pre=\${${nidvar}_pre_${stat}}
	eval post=\${${nidvar}_post_${stat}}

	echo "${!nidvar} pre ${stat} $pre post ${stat} $post"

	[[ $pre -ne $post ]]
}

test_215() {
	cleanup_netns || error "Failed to cleanup netns before test execution"
	cleanup_lnet || error "Failed to unload modules before test execution"

	reinit_dlc || return $?

	add_net "${NETTYPE}1" "${INTERFACES[0]}" || return $?
	add_net "${NETTYPE}2" "${INTERFACES[0]}" || return $?

	local nid1=$($LCTL list_nids | head -n 1)
	local nid2=$($LCTL list_nids | tail --lines 1)

	do_lnetctl peer add --prim $nid1 --nid $nid2 ||
		error "Failed to add peer"

	local npings=25

	for nidvarA in nid1 nid2; do
		src=${!nidvarA}
		dst=${!nidvarA}
		for nidvarB in nid1 nid2; do
			[[ $nidvarA == $nidvarB ]] && continue

			ni_stats_pre

			echo "$LNETCTL ping $dst x $npings"
			for i in $(seq 1 $npings); do
				$LNETCTL ping $dst &>/dev/null ||
					error "$LNETCTL ping $dst failed"
			done

			ni_stats_post

			# No source specified, sends to either NID should cause
			# counts to increase across both NIs
			for nidvar in nid1 nid2; do
				for stat in send_count recv_count; do
					ni_stat_changed $nidvar $stat ||
						error "$stat unchanged for ${!nidvar}"
				done
			done

			ni_stats_pre

			echo "$LNETCTL ping --source $src $dst x $npings"
			for i in $(seq 1 $npings); do
				$LNETCTL ping --source $src $dst &>/dev/null ||
					error "$LNETCTL ping --source $src $dst failed"
			done

			ni_stats_post

			# src nid == dest nid means stats for the _other_ NI
			# should be unchanged
			for nidvar in nid1 nid2; do
				for stat in send_count recv_count; do
					if [[ ${!nidvar} == $src ]]; then
						ni_stat_changed $nidvar $stat ||
							error "$stat unchanged for ${!nidvar}"
					else
						ni_stat_changed $nidvar $stat &&
							error "$stat changed for ${!nidvar}"
					fi
				done
			done
		done
		# Double number of pings for next iteration because the net
		# sequence numbers will have diverged
		npings=$(($npings * 2))
	done

	# Ping from nid1 to nid2 should fail
	do_lnetctl ping --source $nid1 $nid2 &&
		error "ping from $nid1 to $nid2 should fail"

	# Ping from nid2 to nid1 should fail
	do_lnetctl ping --source $nid2 $nid1 &&
		error "ping from $nid2 to $nid1 should fail"

	return 0
}
run_test 215 "Test lnetctl ping --source option"

test_216() {
	[[ ${NETTYPE} == kfi* ]] && skip "kfi doesn't support drop rules"

	local rc=0

	reinit_dlc || return $?

	add_net "${NETTYPE}" "${INTERFACES[0]}" || return $?
	add_net "${NETTYPE}1" "${INTERFACES[0]}" || return $?

	local nids=( $($LCTL list_nids | xargs echo) )

	do_lnetctl discover ${nids[0]} ||
		error "Initial discovery failed"

	do_lnetctl ping --source ${nids[0]} ${nids[0]} ||
		error "Initial ping failed $?"

	do_lnetctl ping --source ${nids[1]} ${nids[1]} ||
		error "Initial ping failed $?"

	local src dst
	for src in "${nids[@]}"; do
		for dst in "${nids[@]}"; do
			$LCTL net_drop_add -r 1 -s $src -d $dst -e network_timeout
		done
	done

	do_lnetctl ping ${nids[0]} || rc=$?

	$LCTL net_drop_del -a

	[[ $rc -eq 0 ]] &&
		error "expected ping to fail"

	check_nid_in_recovq "-p" "${nids[0]}" "0"
	check_nid_in_recovq "-l" "${nids[0]}" "1"

	return 0
}
run_test 216 "Failed send to peer NI owned by local host should not trigger peer NI recovery"

test_217() {
	reinit_dlc || return $?

	[[ $($LNETCTL net show | grep -c nid) -ne 1 ]] &&
		error "Unexpected number of NIs after initalizing DLC"

	do_lnetctl discover 0@lo ||
		error "Failed to discover 0@lo"

	unload_modules
}
run_test 217 "Don't leak memory when discovering peer with nnis <= 1"

test_218() {
	[[ ${NETTYPE} == kfi* ]] && skip "kfi doesn't support drop rules"

	reinit_dlc || return $?

	[[ ${#INTERFACES[@]} -lt 2 ]] &&
		skip "Need two LNet interfaces"

	add_net "${NETTYPE}" "${INTERFACES[0]}" || return $?

	local nid1=$($LCTL list_nids | head -n 1)

	do_lnetctl ping $nid1 ||
		error "ping failed"

	add_net "${NETTYPE}" "${INTERFACES[1]}" || return $?

	local nid2=$($LCTL list_nids | tail --lines 1)

	do_lnetctl ping $nid2 ||
		error "ping failed"

	$LCTL net_drop_add -s $nid1 -d $nid1 -e local_error -r 1

	do_lnetctl ping --source $nid1 $nid1 &&
		error "ping should have failed"

	local health_recovered
	local i

	for i in $(seq 1 5); do
		health_recovered=$($LNETCTL net show -v 2 |
				   grep -c 'health value: 1000')

		if [[ $health_recovered -ne 2 ]]; then
			echo "Wait 1 second for health to recover"
			sleep 1
		else
			break
		fi
	done

	health_recovered=$($LNETCTL net show -v 2 |
			   grep -c 'health value: 1000')

	$LCTL net_drop_del -a

	[[ $health_recovered -ne 2 ]] &&
		do_lnetctl net show -v 2 | egrep -e nid -e health &&
		error "Health hasn't recovered"

	return 0
}
run_test 218 "Local recovery pings should exercise all available paths"

test_219() {
	reinit_dlc || return $?
	add_net "${NETTYPE}" "${INTERFACES[0]}" || return $?
	add_net "${NETTYPE}1" "${INTERFACES[0]}" || return $?

	local nid1=$(lctl list_nids | head -n 1)
	local nid2=$(lctl list_nids | tail --lines 1)

	do_lnetctl ping $nid1 ||
		error "Ping failed $?"
	do_lnetctl ping $nid2 ||
		error "Ping failed $?"

	do_lnetctl discover $nid2 ||
		error "Discovery failed"

	$LNETCTL peer show --nid $nid1 | grep -q $nid2 ||
		error "$nid2 is not listed under $nid1"
}
run_test 219 "Consolidate peer entries"

do_net_add() {
	local node=$1
	local net=$2
	local if=$3

	do_rpc_nodes $node "$LNETCTL net add --net $net --if $if" ||
		error "add $net on interface $if on node $node failed rc=$?"
}

do_route_add() {
	local node=$1
	local net=$2
	local gw=$3

	do_node $node "$LNETCTL route add --net $net --gateway $gw" ||
		error "route add to $net via $gw failed rc=$?"
}

ROUTER=""
ROUTER_INTERFACES=()
RPEER=""
RPEER_INTERFACES=()
init_router_test_vars() {
	local rnodes=$(remote_nodes_list)
	[[ -z $rnodes || $(wc -w <<<$rnodes) -lt 2 ]] &&
		skip "Need at least 2 remote nodes found \"$rnodes\""

	ROUTER=$(awk '{print $1}' <<<$rnodes)
	RPEER=$(awk '{print $2}' <<<$rnodes)

	rnodes=$(comma_list $ROUTER $RPEER)
	local all_nodes=$(comma_list $rnodes $HOSTNAME)

	do_nodes $rnodes $LUSTRE_RMMOD ||
		error "failed to unload modules"

	do_rpc_nodes $rnodes "load_lnet config_on_load=1" ||
		error "Failed to load and configure LNet"

	ROUTER_INTERFACES=( $(do_rpc_nodes --quiet $ROUTER lnet_if_list) )

	RPEER_INTERFACES=( $(do_rpc_nodes --quiet $RPEER lnet_if_list) )

	do_nodes $all_nodes $LUSTRE_RMMOD ||
		error "Failed to unload modules"

	[[ ${#INTERFACES[@]} -eq 0 ]] &&
		error "No interfaces configured for local host $HOSTNAME"
	[[ ${#ROUTER_INTERFACES[@]} -eq 0 ]] &&
		error "No interfaces configured for router $ROUTER"
	[[ ${#RPEER_INTERFACES[@]} -eq 0 ]] &&
		error "No interfaces configured for remote peer $RPEER"

	return 0
}

ROUTER_NIDS=()
RPEER_NIDS=()
LNIDS=()
LOCAL_NET=${NETTYPE}1
REMOTE_NET=${NETTYPE}2
setup_router_test() {
	local mod_opts="$@"

	(( $MDS1_VERSION >= $(version_code 2.15.0) )) ||
		skip "need at least 2.15.0 for load_lnet"

	if [[ ${#RPEER_INTERFACES[@]} -eq 0 ]]; then
		init_router_test_vars ||
			return $?
	fi

	local all_nodes=$(comma_list $ROUTER $RPEER $HOSTNAME)

	do_nodes $all_nodes $LUSTRE_RMMOD ||
		error "failed to unload modules"

	mod_opts+=" alive_router_check_interval=5"
	mod_opts+=" router_ping_timeout=5"
	mod_opts+=" large_router_buffers=4"
	mod_opts+=" small_router_buffers=8"
	mod_opts+=" tiny_router_buffers=16"
	do_rpc_nodes $all_nodes load_lnet "${mod_opts}" ||
		error "Failed to load lnet"

	do_nodes $all_nodes "$LNETCTL lnet configure" ||
		error "Failed to initialize DLC"

	do_net_add $ROUTER $LOCAL_NET ${ROUTER_INTERFACES[0]} ||
		return $?

	do_net_add $ROUTER $REMOTE_NET ${ROUTER_INTERFACES[0]} ||
		return $?

	do_net_add $RPEER $REMOTE_NET ${RPEER_INTERFACES[0]} ||
		return $?

	add_net $LOCAL_NET ${INTERFACES[0]} ||
		return $?

	ROUTER_NIDS=( $(do_node $ROUTER $LCTL list_nids 2>/dev/null |
			xargs echo) )
	RPEER_NIDS=( $(do_node $RPEER $LCTL list_nids 2>/dev/null |
		       xargs echo) )
	LNIDS=( $($LCTL list_nids 2>/dev/null | xargs echo) )
}

do_route_del() {
	local node=$1
	local net=$2
	local gw=$3

	do_nodesv $node "if $LNETCTL route show --net $net --gateway $gw; then \
				$LNETCTL route del --net $net --gateway $gw;   \
			 else						       \
				exit 0;					       \
			 fi"
}

cleanup_router_test() {
	local all_nodes=$(comma_list $HOSTNAME $ROUTER $RPEER)

	do_route_del $HOSTNAME $REMOTE_NET ${ROUTER_NIDS[0]} ||
		error "Failed to delete $REMOTE_NET route"

	do_route_del $RPEER $LOCAL_NET ${ROUTER_NIDS[1]} ||
		error "Failed to delete $LOCAL_NET route"

	do_nodes $all_nodes $LUSTRE_RMMOD ||
		error "failed to unload modules"

	return 0
}

check_route_aliveness() {
	local node="$1"
	local expected="$2"

	local lctl_actual
	local lnetctl_actual
	local chk_intvl
	local i

	chk_intvl=$(cat /sys/module/lnet/parameters/alive_router_check_interval)

	lctl_actual=$(do_node $node $LCTL show_route | awk '{print $7}')
	lnetctl_actual=$(do_node $node $LNETCTL route show -v |
			 awk '/state/{print $NF}')

	for ((i = 0; i < $chk_intvl; i++)); do
		if [[ $lctl_actual == $expected ]] &&
		   [[ $lnetctl_actual == $expected ]]; then
			break
		fi

		echo "wait 1s for route state change"
		sleep 1

		lctl_actual=$(do_node $node $LCTL show_route | awk '{print $7}')
		lnetctl_actual=$(do_node $node $LNETCTL route show -v |
				 awk '/state/{print $NF}')
	done

	[[ $lctl_actual != $expected ]] &&
		error "Wanted \"$expected\" lctl found \"$lctl_actual\""

	[[ $lnetctl_actual != $expected ]] &&
		error "Wanted \"$expected\" lnetctl found \"$lnetctl_actual\""

	return 0
}

check_router_ni_status() {
	local expected_local="$1"
	local expected_remote="$2"

	local actual_local
	local actual_remote
	local chk_intvl
	local timeout
	local i

	chk_intvl=$(cat /sys/module/lnet/parameters/alive_router_check_interval)
	timeout=$(cat /sys/module/lnet/parameters/router_ping_timeout)

	actual_local=$(do_node $ROUTER "$LNETCTL net show --net $LOCAL_NET" |
		       awk '/status/{print $NF}')
	actual_remote=$(do_node $ROUTER "$LNETCTL net show --net $REMOTE_NET" |
			awk '/status/{print $NF}')

	for ((i = 0; i < $((chk_intvl + timeout)); i++)); do
		if [[ $actual_local == $expected_local ]] &&
		   [[ $actual_remote == $expected_remote ]]; then
			break
		fi

		echo "wait 1s for NI state change"
		sleep 1

		actual_local=$(do_node $ROUTER \
			       "$LNETCTL net show --net $LOCAL_NET" |
				awk '/status/{print $NF}')
		actual_remote=$(do_node $ROUTER \
				"$LNETCTL net show --net $REMOTE_NET" |
				awk '/status/{print $NF}')
	done

	[[ $actual_local == $expected_local ]] ||
		error "$LOCAL_NET should be $expected_local"

	[[ $actual_remote == $expected_remote ]] ||
		error "$REMOTE_NET should be $expected_remote"

	return 0
}

do_basic_rtr_test() {
	do_node $ROUTER "$LNETCTL set routing 1" ||
		error "Unable to enable routing on $ROUTER"

	do_route_add $HOSTNAME $REMOTE_NET ${ROUTER_NIDS[0]} ||
		return $?

	do_route_add $RPEER $LOCAL_NET ${ROUTER_NIDS[1]} ||
		return $?

	check_route_aliveness "$HOSTNAME" "up" ||
		return $?

	check_route_aliveness "$RPEER" "up" ||
		return $?

	do_lnetctl ping ${RPEER_NIDS[0]} ||
		error "Failed to ping ${RPEER_NIDS[0]}"

	do_node $RPEER "$LNETCTL ping ${LNIDS[0]}" ||
		error "$RPEER failed to ping ${LNIDS[0]}"

	return 0
}

test_220() {
	setup_router_test || return $?

	do_basic_rtr_test || return $?

	do_rpc_nodes $HOSTNAME,$RPEER load_module ../lnet/selftest/lnet_selftest ||
		error "Failed to load lnet-selftest module"

	$LSTSH -H -t $HOSTNAME -f $RPEER -m rw -s 4k ||
		error "lst failed"

	$LSTSH -H -t $HOSTNAME -f $RPEER -m rw ||
		error "lst failed"

	cleanup_router_test || return $?
}
run_test 220 "Add routes w/default options - check aliveness"

test_221() {
	setup_router_test lnet_peer_discovery_disabled=1 || return $?

	do_basic_rtr_test || return $?

	cleanup_router_test || return $?
}
run_test 221 "Add routes w/DD disabled - check aliveness"

do_aarf_enabled_test() {
	do_node $ROUTER "$LNETCTL set routing 1" ||
		error "Unable to enable routing on $ROUTER"

	check_router_ni_status "down" "down"

	do_lnetctl ping ${RPEER_NIDS[0]} &&
		error "Ping should fail"

	do_node $RPEER "$LNETCTL ping ${LNIDS[0]}" &&
		error "$RPEER ping should fail"

	# Adding a route should cause the router's NI on LOCAL_NET to get up
	do_route_add $HOSTNAME $REMOTE_NET ${ROUTER_NIDS[0]} ||
		return $?

	check_router_ni_status "up" "down" ||
		return $?

	# But route should still be down because of avoid_asym_router_failure
	check_route_aliveness "$HOSTNAME" "down" ||
		return $?

	do_lnetctl ping ${RPEER_NIDS[0]} &&
		error "Ping should fail"

	do_node $RPEER "$LNETCTL ping ${LNIDS[0]}" &&
		error "$RPEER ping should fail"

	# Adding the symmetric route should cause the remote NI to go up and
	# routes to go up
	do_route_add $RPEER $LOCAL_NET ${ROUTER_NIDS[1]} ||
		return $?

	check_router_ni_status "up" "up" ||
		return $?

	check_route_aliveness "$HOSTNAME" "up" ||
		return $?

	check_route_aliveness "$RPEER" "up" ||
		return $?

	do_lnetctl ping ${RPEER_NIDS[0]} ||
		error "Failed to ping ${RPEER_NIDS[0]}"

	do_node $RPEER "$LNETCTL ping ${LNIDS[0]}" ||
		error "$RPEER failed to ping ${LNIDS[0]}"

	# Stop LNet on local host
	do_lnetctl lnet unconfigure ||
		error "Failed to stop LNet rc=$?"

	check_router_ni_status "down" "up" ||
		return $?

	check_route_aliveness "$RPEER" "down" ||
		return $?

	do_lnetctl ping ${RPEER_NIDS[0]} &&
		error "Ping should fail"

	do_node $RPEER "$LNETCTL ping ${LNIDS[0]}" &&
		error "$RPEER ping should fail"

	return 0
}

test_222() {
	setup_router_test avoid_asym_router_failure=1 || return $?

	do_aarf_enabled_test || return $?

	cleanup_router_test || return $?
}
run_test 222 "Check avoid_asym_router_failure=1"

test_223() {
	local opts="avoid_asym_router_failure=1 lnet_peer_discovery_disabled=1"

	setup_router_test $opts || return $?

	do_aarf_enabled_test || return $?

	cleanup_router_test || return $?
}
run_test 223 "Check avoid_asym_router_failure=1 w/DD disabled"

do_aarf_disabled_test() {
	do_node $ROUTER "$LNETCTL set routing 1" ||
		error "Unable to enable routing on $ROUTER"

	check_router_ni_status "down" "down"

	do_route_add $HOSTNAME $REMOTE_NET ${ROUTER_NIDS[0]} ||
		return $?

	check_router_ni_status "up" "down" ||
		return $?

	check_route_aliveness "$HOSTNAME" "up" ||
		return $?

	do_route_add $RPEER $LOCAL_NET ${ROUTER_NIDS[1]} ||
		return $?

	check_router_ni_status "up" "up" ||
		return $?

	check_route_aliveness "$HOSTNAME" "up" ||
		return $?

	check_route_aliveness "$RPEER" "up" ||
		return $?

	do_lnetctl ping ${RPEER_NIDS[0]} ||
		error "Failed to ping ${RPEER_NIDS[0]}"

	do_node $RPEER "$LNETCTL ping ${LNIDS[0]}" ||
		error "$RPEER failed to ping ${LNIDS[0]}"

	# Stop LNet on local host
	do_lnetctl lnet unconfigure ||
		error "Failed to stop LNet rc=$?"

	check_router_ni_status "down" "up" ||
		return $?

	check_route_aliveness "$RPEER" "up" ||
		return $?

	return 0
}

test_224() {
	setup_router_test avoid_asym_router_failure=0 ||
		return $?

	do_aarf_disabled_test ||
		return $?

	cleanup_router_test ||
		return $?
}
run_test 224 "Check avoid_asym_router_failure=0"

test_225() {
	local opts="avoid_asym_router_failure=0 lnet_peer_discovery_disabled=1"

	setup_router_test $opts || return $?

	do_aarf_disabled_test || return $?

	cleanup_router_test ||
		return $?
}
run_test 225 "Check avoid_asym_router_failure=0 w/DD disabled"

test_230() {
	[[ ${NETTYPE} == tcp* ]] ||
		skip "Need tcp NETTYPE"
	# LU-12815
	echo "Check valid values; Should succeed"
	local i
	local lnid
	local cmd
	for ((i = 4; i < 16; i+=1)); do
		reinit_dlc || return $?
		add_net "tcp" "${INTERFACES[0]}" || return $?
		do_lnetctl net set --all --conns-per-peer $i ||
			error "should have succeeded $?"
		$LNETCTL net show -v 1 | grep -q "conns_per_peer: $i" ||
			error "failed to set conns-per-peer to $i"
		lnid="$(lctl list_nids | head -n 1)"
		do_lnetctl ping "$lnid" ||
			error "failed to ping myself"

		# "lctl --net tcp conn_list" prints the list of active
		# connections. Since we're pinging ourselves, there should be
		# 2 Control connections plus 2*conns_per_peer connections
		# created (one Bulk Input, one Bulk Output in each pair).
		# Here's the sample output for conns_per_peer set to 1:
		# 12345-1.1.1.1@tcp I[0]host01->host01:988 2626560/1061296 nonagle
		# 12345-1.1.1.1@tcp O[0]host01->host01:1022 2626560/1061488 nonagle
		# 12345-1.1.1.1@tcp C[0]host01->host01:988 2626560/1061296 nonagle
		# 12345-1.1.1.1@tcp C[0]host01->host01:1023 2626560/1061488 nonagle
		cmd="printf 'network tcp\nconn_list\n' | lctl | grep -c '$lnid'"

		# Expect 2+conns_per_peer*2 connections. Wait no longer
		# than 2 seconds.
		wait_update $HOSTNAME "$cmd" "$((2+i*2))" 2 ||
			error "expected number of tcp connections $((2+i*2))"
	done

	reinit_dlc || return $?
	add_net "tcp" "${INTERFACES[0]}" || return $?
	echo "Set > 127; Should fail"
	do_lnetctl net set --all --conns-per-peer 128 &&
		error "should have failed $?"

	reinit_dlc || return $?
	add_net "tcp" "${INTERFACES[0]}" || return $?

	local default=$($LNETCTL net show -v 1 |
			awk '/conns_per_peer/{print $NF}')

	echo "Set < 0; Should be ignored"
	do_lnetctl net set --all --conns-per-peer -1 ||
		error "should have succeeded $?"
	$LNETCTL net show -v 1 | grep -q "conns_per_peer: ${default}" ||
		error "Did not stay at default"
}
run_test 230 "Test setting conns-per-peer"

test_231() {
	reinit_dlc || return $?

	local net=${NETTYPE}231

	do_lnetctl net add --net $net --if ${INTERFACES[0]} ||
		error "Failed to add net"

	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-expected.yaml
	sed -i 's/peer_timeout: .*$/peer_timeout: 0/' \
		$TMP/sanity-lnet-$testnum-expected.yaml

	reinit_dlc || return $?

	do_lnetctl import $TMP/sanity-lnet-$testnum-expected.yaml ||
		error "Failed to import configuration"

	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml

	compare_yaml_files || error "Wrong config after import"

	do_lnetctl net del --net $net --if ${INTERFACES[0]} ||
		error "Failed to delete net $net"

	do_lnetctl net add --net $net --if ${INTERFACES[0]} --peer-timeout=0 ||
		error "Failed to add net with peer-timeout=0"

	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml

	compare_yaml_files || error "Wrong config after lnetctl net add"

	reinit_dlc || return $?

	# lnet/include/lnet/lib-lnet.h defines DEFAULT_PEER_TIMEOUT 180
	sed -i 's/peer_timeout: .*$/peer_timeout: 180/' \
		$TMP/sanity-lnet-$testnum-expected.yaml

	sed -i '/^.*peer_timeout:.*$/d' $TMP/sanity-lnet-$testnum-actual.yaml

	do_lnetctl import $TMP/sanity-lnet-$testnum-actual.yaml ||
		error "Failed to import config without peer_timeout"

	$LNETCTL export --backup > $TMP/sanity-lnet-$testnum-actual.yaml

	compare_yaml_files
}
run_test 231 "Check DLC handling of peer_timeout parameter"

### Test that linux route is added for each ni
test_250() {
	local skip_param

	[[ ${NETTYPE} == tcp* ]] ||
		skip "Need tcp NETTYPE"
	reinit_dlc || return $?
	add_net "tcp" "${INTERFACES[0]}" || return $?

	skip_param=$(cat /sys/module/ksocklnd/parameters/skip_mr_route_setup)
	[[ ${skip_param:-0} -ne 0 ]] &&
		skip "Need skip_mr_route_setup=0 found $skip_param"

	ip route show table ${INTERFACES[0]} | grep -q "${INTERFACES[0]}"
}
run_test 250 "test that linux routes are added"

test_251() {
	[[ ${NETTYPE} =~ kfi* ]] ||
		skip "Need kfi NETTYPE"

	reinit_dlc || return $?
	add_net "kfi" "${INTERFACES[0]}" || return $?
	add_net "kfi1" "${INTERFACES[0]}" || return $?
	add_net "kfi10" "${INTERFACES[0]}" || return $?
	return 0
}
run_test 251 "Define multiple kfi networks on single interface"

test_252() {
	setup_health_test false || return $?

	local rc=0

	do_rpc_nodes $RNODE unload_modules_local || rc=$?

	if [[ $rc -ne 0 ]]; then
		cleanup_health_test || return $?

		error "Failed to unload modules on $RNODE rc=$rc"
	else
		RLOADED=false
	fi

	local ts1=$(date +%s)

	do_lnetctl ping --timeout 15 ${RNIDS[0]} &&
		error "Expected ping ${RNIDS[0]} to fail"

	local ts2=$(date +%s)

	local delta=$(echo "$ts2 - $ts1" | bc)

	[[ $delta -lt 15 ]] ||
		error "Ping took longer than expected to fail: $delta"

	cleanup_health_test
}
run_test 252 "Ping to down peer should unlink quickly"

do_expired_message_drop_test() {
	local rnid lnid old_tto

	old_tto=$($LNETCTL global show |
		  awk '/transaction_timeout:/{print $NF}')

	[[ -z $old_tto ]] &&
		error "Cannot determine LNet transaction timeout"

	local tto=10

	do_lnetctl set transaction_timeout "${tto}" ||
		error "Failed to set transaction_timeout"

	# We want to consume all peer credits for at least transaction_timeout
	# seconds
	local delay

	delay=$((tto + 1))

	for lnid in "${LNIDS[@]}"; do
		for rnid in "${RNIDS[@]}"; do
			$LCTL net_delay_add -s "${lnid}" -d "${rnid}" \
				-l "${delay}" -r 1 -m GET
		done
	done

	declare -a pcs

	pcs=( $($LNETCTL peer show -v --nid "${RNIDS[0]}" |
		awk '/max_ni_tx_credits:/{print $NF}' |
		xargs echo) )

	[[ ${#RNIDS[@]} -ne ${#pcs[@]} ]] &&
		error "Expect ${#RNIDS[@]} peer credit values found ${#pcs[@]}"

	local rnet lnid lnet i j

	# Need to use --source for multi-rail configs to ensure we consume
	# all available peer credits
	for ((i = 0; i < ${#RNIDS[@]}; i++)); do
		local ping_args="--timeout $((delay+2))"

		rnet=${RNIDS[i]##*@}
		for lnid in ${LNIDS[@]}; do
			lnet=${lnid##*@}
			[[ $rnet == $lnet ]] && break
		done

		ping_args+=" --source ${lnid} ${RNIDS[i]}"
		for j in $(seq 1 "${pcs[i]}"); do
			$LNETCTL ping ${ping_args} 1>/dev/null &
		done

		echo "Issued ${pcs[i]} pings to ${RNIDS[i]} from $lnid"
	done

	# This ping should be queued on peer NI tx credit
	$LNETCTL ping --timeout $((delay+2)) "${RNIDS[0]}" &

	sleep ${delay}

	$LCTL net_delay_del -a

	wait

	# Messages sent from the delay list do not go through
	# lnet_post_send_locked(), thus we should only have a single drop
	local dropped

	dropped=$($LNETCTL peer show -v 2 --nid "${RNIDS[0]}" |
			grep -A 2 dropped_stats |
			awk '/get:/{print $2}' |
			xargs echo |
			sed 's/ /\+/g' | bc)

	[[ $dropped -ne 1 ]] &&
		error "Expect 1 dropped GET but found $dropped"

	do_lnetctl set transaction_timeout "${old_tto}"

	return 0
}

test_253() {
	setup_health_test false || return $?

	do_expired_message_drop_test || return $?

	cleanup_health_test
}
run_test 253 "Message delayed beyond deadline should be dropped (single-rail)"

test_254() {
	setup_health_test true || return $?

	do_expired_message_drop_test || return $?

	cleanup_health_test
}
run_test 254 "Message delayed beyond deadline should be dropped (multi-rail)"

test_255() {
	[[ ${NETTYPE} == tcp* ]] || skip "Need tcp NETTYPE"

	reinit_dlc || return $?

	cleanup_lnet || return $?

	local routes_str="o2ib ${IF0_NET}.[$GW_HOSTNUM-$((GW_HOSTNUM+4))]"
	local network_str="${NETTYPE}(${INTERFACES[0]})"

	load_lnet "networks=\"${network_str}\" routes=\"${routes_str}\"" ||
		error "Failed to load LNet"

	$LCTL net up ||
		error "Failed to load LNet with networks=\"${network_str}\" routes=\"${routes_str}\""

	cat <<EOF > $TMP/sanity-lnet-$testnum-expected.yaml
net:
    - net type: ${NETTYPE}
      local NI(s):
        - interfaces:
              0: ${INTERFACES[0]}
EOF
	append_net_tunables tcp

	echo "route:" >> $TMP/sanity-lnet-$testnum-expected.yaml
	for i in $(seq $GW_HOSTNUM $((GW_HOSTNUM + 4))); do
		cat <<EOF >> $TMP/sanity-lnet-$testnum-expected.yaml
    - net: o2ib
      gateway: ${IF0_NET}.${i}@${NETTYPE}
      hop: -1
      priority: 0
      health_sensitivity: 1
EOF
	done

	echo "peer:" >> $TMP/sanity-lnet-$testnum-expected.yaml
	for i in $(seq $GW_HOSTNUM $((GW_HOSTNUM + 4))); do
		cat <<EOF >> $TMP/sanity-lnet-$testnum-expected.yaml
    - primary nid: ${IF0_NET}.${i}@${NETTYPE}
      Multi-Rail: False
      peer ni:
        - nid: ${IF0_NET}.${i}@${NETTYPE}
EOF
	done

	append_global_yaml

	$LNETCTL export --backup >  $TMP/sanity-lnet-$testnum-actual.yaml ||
		error "export failed $?"

	validate_gateway_nids
}
run_test 255 "Use lnet routes param with pdsh syntax"

test_300() {
	# LU-13274
	local header
	local out=$TMP/$tfile
	local prefix=/usr/include/linux/lnet

	# We use a hard coded prefix so that this test will not fail
	# when run in tree.
	CC=${CC:-cc}
	if ! which $CC > /dev/null 2>&1; then
		skip_env "$CC is not installed"
	fi

	cleanup_lnet || exit 1
	load_lnet

	local cc_args="-Wall -Werror -std=c99 -c -x c /dev/null -o $out"
	if ! [[ -d $prefix ]]; then
		# Assume we're running in tree and fixup the include path.
		prefix=$LUSTRE/../lnet/include/uapi/linux/lnet
		cc_args+=" -I $LUSTRE/../lnet/include/uapi"
	fi

	for header in $prefix/*.h; do
		if ! [[ -f "$header" ]]; then
			continue
		fi

		echo "$CC $cc_args -include $header"
		$CC $cc_args -include $header ||
			error "cannot compile '$header'"
	done
	rm -f $out
}
run_test 300 "packaged LNet UAPI headers can be compiled"

# LU-16081 lnet: Memory leak on adding existing interface

test_301() {
	reinit_dlc || return $?
	do_lnetctl net add --net ${NETTYPE} --if ${INTERFACES[0]} ||
		error "Failed to add net"
	do_lnetctl net add --net ${NETTYPE} --if ${INTERFACES[0]} &&
		error "add net should have failed"
	do_lnetctl net del --net ${NETTYPE} --if ${INTERFACES[0]} ||
		error "Failed to del net"
	unload_modules
}
run_test 301 "Check for dynamic adds of same/wrong interface (memory leak)"

test_302() {
	! [[ $NETTYPE =~ (tcp|o2ib) ]] && skip "Need tcp or o2ib NETTYPE"
	reinit_dlc || return $?

	add_net "${NETTYPE}" "${INTERFACES[0]}" || return $?

	local nid=$($LCTL list_nids)

	do_lnetctl ping ${nid} ||
		error "pinging self failed $?"
	do_lnetctl debug peer --nid ${nid} ||
		error "failed to dump peer debug info $?"
}
run_test 302 "Check that peer debug info can be dumped"

test_303() {
	[[ ${NETTYPE} == tcp* ]] || skip "Need tcp NETTYPE"

	setup_health_test true || return $?

	cleanup_netns || error "Failed to cleanup netns before test execution"
	setup_fakeif || error "Failed to add fake IF"
	have_interface "$FAKE_IF" ||
		error "Expect $FAKE_IF configured but not found"

	add_net "${NETTYPE}99" "$FAKE_IF" || return $?

	local nid=$($LCTL list_nids | tail --lines 1)

	# Our updated config should be pushed to RNODE
	local found=$(do_node $RNODE "$LNETCTL peer show --nid $nid")

	[[ -z $found ]] && error "Peer not updated on $RNODE"

	local prim=$($LCTL list_nids | head -n 1)

	if ! grep -q -- " primary nid: $prim"<<<"${found}"; then
		echo "$found"
		error "Wrong primary nid"
	fi

	echo "Set $FAKE_IF down"
	echo "ip link set dev $FAKE_IF down"
	ip link set dev $FAKE_IF down
	check_ni_status "$nid" down

	local hval=$(do_node $RNODE "$LNETCTL peer show --nid $nid -v 2 | \
				     grep -e '- nid:' -e 'health value:'")

	hval=$(grep -A 1 $nid<<<"$hval" | tail -n 1 | awk '{print $NF}')
	(( hval < 1000 )) ||
		error "Expect $hval < 1000"

	return 0
}
run_test 303 "Check peer NI health after link down"

test_304() {
	[[ ${NETTYPE} == tcp* ]] || skip "Need tcp NETTYPE"

	cleanup_netns || error "Failed to cleanup netns before test execution"
	cleanup_lnet || error "Failed to unload modules before test execution"

	setup_fakeif || error "Failed to add fake IF"
	have_interface "$FAKE_IF" ||
		error "Expect $FAKE_IF configured but not found"

	reinit_dlc || return $?

	add_net "tcp" "${INTERFACES[0]}" || return $?
	add_net "tcp" "$FAKE_IF" || return $?

	local nid1=$(lctl list_nids | head -n 1)
	local nid2=$(lctl list_nids | tail --lines 1)

	check_ni_status "$nid1" up
	check_ni_status "$nid2" up

	do_lnetctl peer add --prim_nid ${nid2} --lock_prim ||
		error "peer add failed $?"
	local locked_peer_state=($(do_lnetctl peer show -v 4 --nid ${nid2} |
		awk '/peer state/{print $NF}'))

	# Expect peer state bits:
	#   LNET_PEER_MULTI_RAIL(0) | LNET_PEER_CONFIGURED(3) |
	#   LNET_PEER_LOCK_PRIMARY(20)
	(( $locked_peer_state != "1048585")) &&
		error "Wrong peer state \"$locked_peer_state\" expected 1048585"

	# Clear LNET_PEER_CONFIGURED bit and verify
	do_lnetctl peer set --nid ${nid2} --state 1048577 ||
		error "peer add failed $?"
	locked_peer_state=($(do_lnetctl peer show -v 4 --nid ${nid2} |
		awk '/peer state/{print $NF}'))
	(( $locked_peer_state != "1048577")) &&
		error "Wrong peer state \"$locked_peer_state\" expected 1048577"
	do_lnetctl discover ${nid1} ||
		error "Failed to discover peer"

	# Expect nid2 and nid1 peer entries to be consolidated,
	# nid2 to stay primary
	cat <<EOF >> $TMP/sanity-lnet-$testnum-expected.yaml
peer:
    - primary nid: ${nid2}
      Multi-Rail: True
      peer ni:
        - nid: ${nid1}
          state: NA
        - nid: ${nid2}
          state: NA
EOF
	$LNETCTL peer show > $TMP/sanity-lnet-$testnum-actual.yaml
	compare_yaml_files ||
		error "Unexpected peer configuration"

	locked_peer_state=($(do_lnetctl peer show -v 4 --nid ${nid2} |
		awk '/peer state/{print $NF}'))
	# Expect peer state bits to be added:
	#   LNET_PEER_DISCOVERED(4) | LNET_PEER_NIDS_UPTODATE(8)
	(( $locked_peer_state != "1048849")) &&
		error "Wrong peer state \"$locked_peer_state\" expected 1048849"
	return 0
}
run_test 304 "Check locked primary peer nid consolidation"

check_parameter() {
	local para=$1
	local value=$2

	echo "check parameter ${para} value ${value}"

	return $(( $(do_lnetctl net show -v | \
		     tee /dev/stderr | \
		     grep -c "^ \+${para}: ${value}$") != 1 ))
}

static_config() {
	local module=$1
	local setting=$2

	cleanup_lnet || error "Failed to cleanup LNet"

	load_module ../libcfs/libcfs/libcfs ||
		error "Failed to load module libcfs rc = $?"

	load_module ../lnet/lnet/lnet ||
		error "Failed to load module lnet rc = $?"

	echo "loading ${module} ${setting} type ${NETTYPE}"
	load_module "${module}" "${setting}" ||
		error "Failed to load module ${module} rc = $?"

	do_lnetctl lnet configure --all || error "lnet configure failed rc = $?"

	return 0
}

test_310() {
	local value=65

	if [[ ${NETTYPE} == tcp* ]];then
		static_config "../lnet/klnds/socklnd/ksocklnd" \
			      "sock_timeout=${value}"
	elif [[ ${NETTYPE} == o2ib* ]]; then
		static_config "../lnet/klnds/o2iblnd/ko2iblnd" \
			      "timeout=${value}"
	elif [[ ${NETTYPE} == gni* ]]; then
		static_config "../lnet/klnds/gnilnd/kgnilnd" \
			      "timeout=${value}"
	else
		skip "NETTYPE ${NETTYPE} not supported"
	fi

	check_parameter "timeout" $value

	return $?
}
run_test 310 "Set timeout and verify"

test_311() {
	[[ $NETTYPE == kfi* ]] ||
		skip "Need kfi network type"

	setupall || error "setupall failed"

	mkdir -p $DIR/$tdir || error "mkdir failed"
	dd if=/dev/zero of=$DIR/$tdir/$tfile bs=1M count=1 oflag=direct ||
		error "dd write failed"

	local list=$(comma_list $(osts_nodes))

#define CFS_KFI_FAIL_WAIT_SEND_COMP1 0xF115
	do_nodes $list $LCTL set_param fail_loc=0x8000F115
	dd if=$DIR/$tdir/$tfile of=/dev/null bs=1M count=1 ||
		error "dd read failed"

	rm -f $DIR/$tdir/$tfile
	rmdir $DIR/$tdir

	cleanupall || error "Failed cleanup"
}
run_test 311 "Fail bulk put in send wait completion"

test_312() {
	[[ $NETTYPE == kfi* ]] ||
		skip "Need kfi network type"

	setupall || error "setupall failed"

	mkdir -p $DIR/$tdir || error "mkdir failed"

	local list=$(comma_list $(osts_nodes))

#define CFS_KFI_FAIL_WAIT_SEND_COMP3 0xF117
	do_nodes $list $LCTL set_param fail_loc=0x8000F117
	dd if=/dev/zero of=$DIR/$tdir/$tfile bs=1M count=1 oflag=direct ||
		error "dd write failed"

	local tfile2="$DIR/$tdir/testfile2"

	do_nodes $list $LCTL set_param fail_loc=0x8000F117
	dd if=$DIR/$tdir/$tfile of=$tfile2 bs=1M count=1 oflag=direct ||
		error "dd read failed"

	rm -f $DIR/$tdir/$tfile
	rm -f $tfile2
	rmdir $DIR/$tdir

	cleanupall || error "Failed cleanup"
}
run_test 312 "TAG_RX_OK is possible after TX_FAIL"

check_udsp_prio() {
	local target_net="${1}"
	local target_nid="${2}"
	local expect_net="${3}"
	local expect_nid="${4}"
	local type="${5}"

	declare -a nids
	declare -a net_prios
	declare -a nid_prios

	nids=( $($LNETCTL ${type} show -v 5 | awk '/-\s+nid:/{print $NF}' |
		 xargs echo) )

	net_prios=( $($LNETCTL ${type} show -v 5 |
		      awk '/net priority:/{print $NF}' | xargs echo) )

	nid_prios=( $($LNETCTL ${type} show -v 5 |
		      awk '/nid priority:/{print $NF}' | xargs echo) )

	(( ${#nids[@]} != ${#net_prios[@]} )) &&
		error "Wrong # net prios ${#nids[@]} != ${#net_prios[@]}"

	(( ${#nids[@]} != ${#nid_prios[@]} )) &&
		error "Wrong # nid prios ${#nids[@]} != ${#nid_prios[@]}"

	local i

	for ((i = 0; i < ${#nids[@]}; i++)); do
		[[ -n ${target_net} ]] &&
			[[ ${nids[i]##*@} != "${target_net}" ]] &&
			continue
		[[ -n ${target_nid} ]] &&
			[[ ${nids[i]} != "${target_nid}" ]] &&
			continue

		echo "${nids[i]}: net_prio ${net_prios[i]} expect ${expect_net}"
		(( net_prios[i] != expect_net )) &&
			error "Wrong net priority \"${net_prios[i]}\" expect ${expect_net}"

		echo "${nids[i]}: nid_prio ${nid_prios[i]} expect ${expect_nid}"
		(( nid_prios[i] != expect_nid )) &&
			error "Wrong nid priority \"${nid_prios[i]}\" expect ${expect_nid}"
	done

	return 0
}

check_peer_udsp_prio() {
	check_udsp_prio "${1}" "${2}" "${3}" "${4}" "peer"
}

check_net_udsp_prio() {
	check_udsp_prio "${1}" "${2}" "${3}" "${4}" "net"
}

test_400() {
	reinit_dlc || return $?

	do_lnetctl udsp add --src tcp --priority 0 ||
		error "Failed to add udsp rule"
	do_lnetctl udsp del --idx 0 ||
		error "Failed to del udsp rule"
	unload_modules
}
run_test 400 "Check for udsp add/delete net rule without net num"

test_401() {
	reinit_dlc || return $?

	do_lnetctl net add --net ${NETTYPE} --if ${INTERFACES[0]} ||
		error "Failed to add net"

	do_lnetctl udsp add --dst ${NETTYPE} --prio 1 ||
		error "Failed to add peer net priority rule"

	do_lnetctl discover $($LCTL list_nids | head -n 1) ||
		error "Failed to discover peer"

	check_peer_udsp_prio "${NETTYPE}" "" "1" "-1"

	return 0
}
run_test 401 "Discover peer after adding peer net UDSP rule"

test_402() {
	reinit_dlc || return $?

	do_lnetctl udsp add --dst kfi --priority 0 ||
		error "Failed to add UDSP rule"

	do_lnetctl peer add --prim 402@kfi ||
		error "Failed to add peer"

	return 0
}
run_test 402 "Destination net rule should not panic"

complete_test $SECONDS
cleanup_testsuite
exit_status
