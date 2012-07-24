````
=======================================================
 _  _  _ _     _ _____    _    _______ _       _______ 
| || || | |   | (_____)  | |  (_______) |     (_______)
| || || | |__ | |  _      \ \  _      | |      _____   
| ||_|| |  __)| | | |      \ \| |     | |     |  ___)  
| |___| | |   | |_| |_ _____) ) |_____| |_____| |_____ 
 \______|_|   |_(_____|______/ \______)_______)_______)
 - - - Signaling the start of next generation telephony
=======================================================
````

Whistle
=======

What is Whistle?
----------------

In short, it is a scalable, distributed, cloud-based telephony platform that allows you to build powerful telephony applications with a rich set of APIs.

Learn More
----------

* Visit http://2600hz.org
* Read more at http://wiki.2600hz.org
* Join us on IRC @ freenode.net in #2600hz

Install Kazoo
=============

https://2600hz.atlassian.net/wiki/display/docs/Step+5+-+Install+Kazoo

1. CentOS / RedHat

    yum install -y git

2. Debian / Ubuntu

    apt-get install -y git-core

Build the Beams:
----------------

    git clone git://github.com/grengojbo/2600hz-platform.git /opt/whistle
    cd /opt/whistle/bin
    ./build_beams.sh
    ///You can ignore the following error at the end: ./build_beams.sh: line 96: cd: /opt/whistle/whistle_apps/build_beams.sh: No such file or directory



