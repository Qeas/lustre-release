"""
@PRIMARY: N/A
@PRIMARY_DESC: Verify functionality of UDSP rule that prioritizes a source net
@SECONDARY: N/A
@DESIGN: N/A
@TESTCASE:
- configure two networks, multiple nids per network
- add udsp rule that gives one of the networks highest priority
- generate traffic
- verify that the network with the highest priority was used
"""

import os
import yaml
import lnetconfig
from lutf import agents, me
from lutf_basetest import *
from lnet import TheLNet
from lutf_exception import LUTFError
from lnet_helpers import LNetHelpers
from lustre_node import SimpleLustreNode

MIN_NODES = 2
MIN_IFS_PER_NODE = 4
PING_TIMES = 10
PING_NID_NUM = 0
LOCAL_NETS = ['tcp', 'tcp1']
USE_NET_NUM = [0]

class TestLustreTraffic:
        def __init__(self, target=None):
                self.lh = LNetHelpers(os.path.abspath(__file__), target=target)
                self.sln = SimpleLustreNode(os.path.abspath(__file__), target=target)

def getStatNet(stats_dict, net_list, net_num, nid_stat_str):
	stat_val = 0
	for x in stats_dict:
		if (x['net type'] == net_list[net_num]):
			for y in x['local NI(s)']:
					stat_val += y['statistics'][nid_stat_str]
	return stat_val


def run():
	la = agents.keys()
	if len(la) < MIN_NODES:
		return lutfrc(LUTF_TEST_SKIP, "Not enough agents to run the test")
	nodes = []
	try:
		for i in range(0, MIN_NODES):
			node = TestLustreTraffic(la[i])
			t = node.lh
			intfs = t.get_available_devs()
			if len(intfs) < MIN_IFS_PER_NODE:
				return lutfrc(LUTF_TEST_SKIP, "Not enough interfaces")
			t.configure_lnet()
			if not t.check_udsp_present():
				return lutfrc(LUTF_TEST_SKIP, "UDSP feature is missing")
			for j, net in enumerate(LOCAL_NETS):
				half = len(intfs)//len(LOCAL_NETS)
				net_intfs_list = intfs[half*(j):half*(j+1)]
				t.configure_net(net, net_intfs_list)
			t.set_discovery(1)
			nodes.append(node)

		main = nodes[1]
		main_nids = main.lh.list_nids()
		agent = nodes[0]
		agent_nids = agent.lh.list_nids()

		# discover all the peers from main
		if len(main.lh.discover(agent_nids[0])) == 0:
			return lutfrc(LUTF_TEST_FAIL, "unable to discover" ,
				target=agent_nids[0])

		rc = main.lh.check_udsp_empty()
		if not rc:
			return lutfrc(LUTF_TEST_FAIL, "UDSP list not empty")

		for net_num in USE_NET_NUM:
			rc = main.lh.exec_udsp_cmd(" add --src "+LOCAL_NETS[net_num])

		before_stats_main = main.lh.get_net_stats()
		print(before_stats_main)

		for i in range(0, PING_TIMES):
			rc = main.lh.exec_ping(agent_nids[PING_NID_NUM])
			if not rc:
				return lutfrc(LUTF_TEST_FAIL, "ping failed")

		after_stats_main = main.lh.get_net_stats()
		print(after_stats_main)

		send_count_before = {}
		send_count_after = {}
		total_send_count_before = 0
		total_send_count_after = 0
		for net_num in USE_NET_NUM:
			send_count_before[net_num] = getStatNet(before_stats_main, LOCAL_NETS, net_num, 'send_count')
			total_send_count_before += send_count_before[net_num]
			send_count_after[net_num] = getStatNet(after_stats_main, LOCAL_NETS, net_num, 'send_count')
			total_send_count_after += send_count_after[net_num]

		print(send_count_before, send_count_after)


		# Check stats:
		# 1) expect the total send_count to be no less than the number of pings issued
		# 2) expect the send count on the preferred net to increase by no less than the
		#    number of pings issued
		if (total_send_count_after - total_send_count_before) < PING_TIMES:
			return lutfrc(LUTF_TEST_FAIL, "total send count mismatch")

		for net_num in USE_NET_NUM:
			if abs(send_count_after[net_num] - send_count_before[net_num]) < PING_TIMES:
				print("send count increase on network ", LOCAL_NETS[net_num],
			      	      " insufficient. Expected ", PING_TIMES, " got",
				      abs(send_count_after[net_num] - send_count_before[net_num]))
				return lutfrc(LUTF_TEST_FAIL, "send count increase insufficient")

		for n in nodes:
			n.lh.unconfigure_lnet()

		return lutfrc(LUTF_TEST_PASS)
	except Exception as e:
		for n in nodes:
			n.lh.uninit()
		raise e

