#!/bin/python
import subprocess
import sys



subprocess.check_output('cd /',shell=True);

subprocess.call('ansible-playbook vmcheck.yml', shell=True);
subprocess.call('ansible-playbook vmstart.yml', shell=True);

