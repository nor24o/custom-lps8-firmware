import unittest
from decoder_js import run_script


class JavaScriptTests(unittest.TestCase):
    def test_decode(self):
        self.assertEqual(run_script('return {temperature: ((bytes[0]<<8)|bytes[1])/10};', bytes.fromhex('0104'), '0104'), {'temperature':26})

    def test_timeout(self):
        with self.assertRaises(ValueError):
            run_script('while(true){}', b'1', '31')

    def test_no_host_bindings(self):
        result = run_script('return {require: typeof require, process: typeof process, network: typeof fetch};', b'1', '31')
        self.assertEqual(set(result.values()), {'undefined'})

    def test_condition(self):
        self.assertTrue(run_script('return bytes[0]===202;', bytes.fromhex('CAFE'), 'CAFE', condition=True))

    def test_requires_object(self):
        with self.assertRaises(ValueError):
            run_script('return 7;', b'1', '31')


if __name__ == '__main__':
    unittest.main()
