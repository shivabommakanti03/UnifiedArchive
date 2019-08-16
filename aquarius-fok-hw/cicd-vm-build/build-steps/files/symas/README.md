# Philips

All content for the Philips project

* Clone/pull content to /opt/philips on crwth
* Create checksums of all files: 

	find . -type f | grep -vF ./manifest-sha224 | sort | xargs sha224sum > manifest-sha224
* Tar content to LDAPServerSetup-MMDDYYYY.tgz file in /home/customer/philips/SaveHere directory

	tar czf /home/customer/philips/SaveHere/ServerSetup.tgz .

Notes for Philips:
* ServerSetup.tgz file to be extracted to /root/setup/platform-installers/symas/ on the Philips VM
* The ServerSetup script should be copied to /root/bin
        cp ServerSetup /root/bin/
        chmod 500 /root/bin/ServerSetup

	Caution: Any existing modifications to the script will be overwritten
* The $1 variable in the ServerSetup script should equal the FQDN of the AC Domain Controller
