import os
import sqlite3
import tempfile
import unittest
from datetime import datetime
from unittest.mock import patch
import bobcat_lora_bridge as bridge


class RuleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.nodes = os.path.join(self.temp.name, 'nodes.db')
        self.ram = os.path.join(self.temp.name, 'ram.db')
        with sqlite3.connect(self.nodes) as db:
            db.execute('CREATE TABLE node_links (link_id INTEGER, name TEXT, source_node TEXT, trigger_field TEXT, operator TEXT, threshold_val REAL, target_node TEXT, action_type TEXT, action_payload TEXT, turnaround_delay_ms INTEGER, cooldown_sec INTEGER, last_triggered TEXT, last_status TEXT, enabled INTEGER)')
        with sqlite3.connect(self.ram) as db:
            db.execute('CREATE TABLE link_execution_logs (link_id INTEGER,timestamp TEXT,event_type TEXT,source_node TEXT,target_node TEXT,tx_status TEXT,details TEXT)')
        self.paths = patch.multiple(bridge, DB_NODES_PATH=self.nodes, DB_RAM_PATH=self.ram)
        self.paths.start()
        self.addCleanup(self.paths.stop)

    def add(self, operator, last=None):
        with sqlite3.connect(self.nodes) as db:
            db.execute('INSERT INTO node_links VALUES (1,?,?,?,?,?,?,?,?,?,?,?,?,?)', ('test','CAFE-01','temperature',operator,25,'TARGET','lora','0101',1000,60,last,None,1))

    def test_equal_threshold_and_nonblocking_delay(self):
        self.add('>=')
        with patch.object(bridge.threading, 'Timer') as timer, patch.object(bridge, 'dispatch_lora_downlink', return_value=True) as dispatch:
            bridge.evaluate_linking_rules('CAFE-01', {'temperature':25})
            self.assertEqual(timer.call_args.args[0], 1)
            dispatch.assert_not_called()
            timer.call_args.args[1]()
            dispatch.assert_called_once_with('TARGET', '0101')
            with sqlite3.connect(self.ram) as db:
                self.assertEqual(db.execute('SELECT tx_status FROM link_execution_logs').fetchone()[0], 'DISPATCHED')

    def test_less_or_equal(self):
        self.add('<=')
        with patch.object(bridge.threading, 'Timer') as timer:
            bridge.evaluate_linking_rules('CAFE-01', {'temperature':25})
            timer.assert_called_once()

    def test_utc_cooldown(self):
        self.add('>', datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S'))
        with patch.object(bridge.threading, 'Timer') as timer:
            bridge.evaluate_linking_rules('CAFE-01', {'temperature':26})
            timer.assert_not_called()


if __name__ == '__main__':
    unittest.main()
