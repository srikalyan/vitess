#!/usr/bin/python

import warnings
# Dropping a table inexplicably produces a warning despite
# the "IF EXISTS" clause. Squelch these warnings.
warnings.simplefilter("ignore")

import logging
import os
import time
import traceback
import threading
import unittest

import MySQLdb

import tablet
import utils
from vtdb import dbexceptions
from vtdb import update_stream_service
from vtdb import vtclient
from zk import zkocc


master_tablet = tablet.Tablet(62344)
replica_tablet = tablet.Tablet(62345)
master_host = "localhost:%u" % master_tablet.port
replica_host = "localhost:%u" % replica_tablet.port
zkocc_client = zkocc.ZkOccConnection("localhost:%u" % utils.zkocc_port_base,
                                     "test_nj", 30.0)
master_start_position = None

def _get_master_current_position():
  return str(utils.mysql_query(62344, 'vt_test_keyspace', 'show master status')[0][4])


def _get_repl_current_position():
  conn = MySQLdb.Connect(user='vt_dba',
                         unix_socket=os.path.join(utils.vtdataroot, 'vt_%010d/mysql.sock' % 62345),
                         db='vt_test_keyspace')
  cursor = MySQLdb.cursors.DictCursor(conn)
  cursor.execute('show master status')
  res = cursor.fetchall()
  return str(res[0]['Group_ID'])


def setUpModule():
  try:
    utils.zk_setup()

  # start mysql instance external to the test
    setup_procs = [master_tablet.init_mysql(),
                   replica_tablet.init_mysql()
                   ]
    utils.wait_procs(setup_procs)
    setup_tablets()
  except:
    tearDownModule()
    raise


def tearDownModule():
  if utils.options.skip_teardown:
    return
  logging.debug("Tearing down the servers and setup")
  teardown_procs = [master_tablet.teardown_mysql(),
                    replica_tablet.teardown_mysql()]
  utils.wait_procs(teardown_procs, raise_on_error=False)

  utils.zk_teardown()
  tablet.Tablet.tablets_running = 2
  master_tablet.kill_vttablet()
  replica_tablet.kill_vttablet()
  utils.kill_sub_processes()
  utils.remove_tmp_files()
  master_tablet.remove_tree()
  replica_tablet.remove_tree()

def setup_tablets():
  # Start up a master mysql and vttablet
  logging.debug("Setting up tablets")
  utils.run_vtctl('CreateKeyspace test_keyspace')
  master_tablet.init_tablet('master', 'test_keyspace', '0')
  replica_tablet.init_tablet('replica', 'test_keyspace', '0')
  utils.run_vtctl('RebuildShardGraph test_keyspace/0')
  utils.validate_topology()
  master_tablet.create_db('vt_test_keyspace')
  replica_tablet.create_db('vt_test_keyspace')

  utils.run_vtctl('RebuildKeyspaceGraph test_keyspace')
  zkocc_server = utils.zkocc_start()

  master_tablet.start_vttablet()
  replica_tablet.start_vttablet()
  utils.run_vtctl('SetReadWrite ' + master_tablet.tablet_alias)
  utils.check_db_read_write(62344)

  for t in [master_tablet, replica_tablet]:
    t.reset_replication()
  utils.run_vtctl('ReparentShard -force test_keyspace/0 ' + master_tablet.tablet_alias, auto_log=True)

  # reset counter so tests don't assert
  tablet.Tablet.tablets_running = 0
  setup_schema()
  master_tablet.vquery("set vt_schema_reload_time=86400", path="test_keyspace/0")
  replica_tablet.vquery("set vt_schema_reload_time=86400", path="test_keyspace/0")

def setup_schema():
  global master_start_position
  master_start_position = _get_master_current_position()
  master_tablet.mquery('vt_test_keyspace', _create_vt_insert_test)
  master_tablet.mquery('vt_test_keyspace', _create_vt_a)
  master_tablet.mquery('vt_test_keyspace', _create_vt_b)

class TestUpdateStream(unittest.TestCase):

  def _get_master_stream_conn(self):
    #return update_stream_service.UpdateStreamConnection(master_host, 30, user="ala", password="ma kota")
    return update_stream_service.UpdateStreamConnection(master_host, 30)

  def _get_replica_stream_conn(self):
    #return update_stream_service.UpdateStreamConnection(replica_host, 30, user="ala", password="ma kota")
    return update_stream_service.UpdateStreamConnection(replica_host, 30)


  def _test_service_disabled(self):
    start_position = _get_repl_current_position()
    logging.debug("_test_service_disabled starting @ %s" % start_position)
    self._exec_vt_txn(master_host, _populate_vt_insert_test)
    self._exec_vt_txn(master_host, ['delete from vt_insert_test',])
    utils.run_vtctl(['ChangeSlaveType', replica_tablet.tablet_alias, 'spare'])
    #  time.sleep(20)
    replica_conn = self._get_replica_stream_conn()
    logging.debug("dialing replica update stream service")
    replica_conn.dial()
    try:
      data = replica_conn.stream_start(start_position)
    except Exception, e:
      logging.debug(str(e))
      if str(e) == "update stream service is not enabled":
        logging.debug("Test Service Disabled: Pass")
      else:
        self.fail("Test Service Disabled: Fail - did not throw the correct exception")

    v = utils.get_vars(replica_tablet.port)
    if v['UpdateStreamState']['Current'] != 'Disabled':
      self.fail("Update stream service should be 'Disabled' but is '%s'" % v['UpdateStreamState']['Current'])

  def perform_writes(self, count):
    for i in xrange(count):
      self._exec_vt_txn(master_host, _populate_vt_insert_test)
      self._exec_vt_txn(master_host, ['delete from vt_insert_test',])


  def _test_service_enabled(self):
    start_position = _get_repl_current_position()
    logging.debug("_test_service_enabled starting @ %s" % start_position)
    utils.run_vtctl(['ChangeSlaveType', replica_tablet.tablet_alias, 'replica'])
    logging.debug("sleeping a bit for the replica action to complete")
    time.sleep(10)
    thd = threading.Thread(target=self.perform_writes, name='write_thd', args=(400,))
    thd.daemon = True
    thd.start()
    replica_conn = self._get_replica_stream_conn()
    replica_conn.dial()

    try:
      data = replica_conn.stream_start(start_position)
      for i in xrange(10):
        data = replica_conn.stream_next()
        if data['Category'] == 'DML' and utils.options.verbose == 2:
          logging.debug("Test Service Enabled: Pass")
          break
    except Exception, e:
      raise utils.TestError("Exception in getting stream from replica: %s\n Traceback %s",str(e), traceback.print_exc())
    thd.join(timeout=30)

    v = utils.get_vars(replica_tablet.port)
    if v['UpdateStreamState']['Current'] != 'Enabled':
      self.fail("Update stream service should be 'Enabled' but is '%s'" % v['UpdateStreamState']['Current'] )

    logging.debug("Testing enable -> disable switch starting @ %s" % start_position)
    replica_conn = self._get_replica_stream_conn()
    replica_conn.dial()
    disabled_err = False
    txn_count = 0
    try:
      data = replica_conn.stream_start(start_position)
      utils.run_vtctl(['ChangeSlaveType', replica_tablet.tablet_alias, 'spare'])
      #logging.debug("Sleeping a bit for the spare action to complete")
      #time.sleep(20)
      while data:
        data = replica_conn.stream_next()
        if data is not None and data['Category'] == 'POS':
          txn_count +=1
      logging.error("Test Service Switch: FAIL")
      return
    except dbexceptions.DatabaseError, e:
      self.assertEqual("Fatal Service Error: Disconnecting because the Update Stream service has been disabled", str(e))
    except Exception, e:
      logging.error("Exception: %s", str(e))
      logging.error("Traceback: %s", traceback.print_exc())
      raise utils.TestError("Update stream returned error '%s'", str(e))
    logging.debug("Streamed %d transactions before exiting" % txn_count)

  def _vtdb_conn(self, host):
    conn = vtclient.VtOCCConnection(zkocc_client, 'test_keyspace', '0', "master", 30)
    conn.connect()
    return conn

  def _exec_vt_txn(self, host, query_list=None):
    if not query_list:
      return
    vtdb_conn = self._vtdb_conn(host)
    vtdb_cursor = vtdb_conn.cursor()
    vtdb_conn.begin()
    for q in query_list:
      vtdb_cursor.execute(q, {})
    vtdb_conn.commit()

  #The function below checks the parity of streams received
  #from master and replica for the same writes. Also tests
  #transactions are retrieved properly.
  def test_stream_parity(self):
    master_start_position = _get_master_current_position()
    replica_start_position = _get_repl_current_position()
    logging.debug("run_test_stream_parity starting @ %s" % master_start_position)
    master_txn_count = 0
    replica_txn_count = 0
    self._exec_vt_txn(master_host, _populate_vt_a(15))
    self._exec_vt_txn(master_host, _populate_vt_b(14))
    self._exec_vt_txn(master_host, ['delete from vt_a',])
    self._exec_vt_txn(master_host, ['delete from vt_b',])
    master_conn = self._get_master_stream_conn()
    master_conn.dial()
    master_events = []
    data = master_conn.stream_start(master_start_position)
    master_events.append(data)
    for i in xrange(21):
      data = master_conn.stream_next()
      master_events.append(data)
      if data['Category'] == 'POS':
        master_txn_count +=1
        break
    replica_events = []
    replica_conn = self._get_replica_stream_conn()
    replica_conn.dial()
    data = replica_conn.stream_start(replica_start_position)
    replica_events.append(data)
    for i in xrange(21):
      data = replica_conn.stream_next()
      replica_events.append(data)
      if data['Category'] == 'POS':
        replica_txn_count +=1
        break
    if len(master_events) != len(replica_events):
      logging.debug("Test Failed - # of records mismatch, master %s replica %s" % (master_events, replica_events))
    for master_val, replica_val in zip(master_events, replica_events):
      master_data = master_val
      replica_data = replica_val
      self.assertEqual(master_data, replica_data, "Test failed, data mismatch - master '%s' and replica position '%s'" % (master_data, replica_data))
    logging.debug("Test Writes: PASS")


  def test_ddl(self):
    global master_start_position
    start_position = master_start_position
    logging.debug("test_ddl: starting @ %s" % start_position)
    master_conn = self._get_master_stream_conn()
    master_conn.dial()
    data = master_conn.stream_start(start_position)
    self.assertEqual(data['Sql'], _create_vt_insert_test, "DDL didn't match original")

  #This tests the service switch from disable -> enable -> disable
  def test_service_switch(self):
    self._test_service_disabled()
    self._test_service_enabled()
    # The above tests leaves the service in disabled state, hence enabling it.
    utils.run_vtctl(['ChangeSlaveType', replica_tablet.tablet_alias, 'replica'])

  def test_log_rotation(self):
    start_position = _get_master_current_position()
    master_tablet.mquery('vt_test_keyspace', "flush logs")
    self._exec_vt_txn(master_host, _populate_vt_a(15))
    self._exec_vt_txn(master_host, ['delete from vt_a',])
    master_conn = self._get_master_stream_conn()
    master_conn.dial()
    data = master_conn.stream_start(start_position)
    master_txn_count = 0
    logs_correct = False
    while master_txn_count <=2:
      data = master_conn.stream_next()
      if data['Category'] == 'POS':
        master_txn_count +=1
        if int(start_position) < int(data['GroupId']):
          logs_correct = True
          logging.debug("Log rotation correctly interpreted")
          break
    if not logs_correct:
      self.fail("Flush logs didn't get properly interpreted")

_create_vt_insert_test = '''create table if not exists vt_insert_test (
id bigint auto_increment,
msg varchar(64),
primary key (id)
) Engine=InnoDB'''

_populate_vt_insert_test = [
    "insert into vt_insert_test (msg) values ('test %s')" % x
    for x in xrange(4)]

_create_vt_a = '''create table if not exists vt_a (
eid bigint,
id int,
primary key(eid, id)
) Engine=InnoDB'''

def _populate_vt_a(count):
  return ["insert into vt_a (eid, id) values (%d, %d)" % (x, x)
          for x in xrange(count+1) if x >0]

_create_vt_b = '''create table if not exists vt_b (
eid bigint,
name varchar(128),
foo varbinary(128),
primary key(eid, name)
) Engine=InnoDB'''

def _populate_vt_b(count):
  return ["insert into vt_b (eid, name, foo) values (%d, 'name %s', 'foo %s')" % (x, x, x)
          for x in xrange(count)]

_create_vt_c = '''create table vt_c (
eid bigint auto_increment,
id int default 1,
name varchar(128) default 'name',
foo varchar(128),
primary key(eid, id, name)
) Engine=InnoDB'''

if __name__ == '__main__':
  utils.main()
