# eBlocker DNS

eBlocker's DNS server listens on UDP port 5300. It reads its configuration from a local Redis.

For filtering domains the server connects to the local eBlocker Icapserver at UDP port 7777.

## Build Debian package

Install required packages:

    sudo apt-get install ruby-hitimes ruby-nio4r

Build a Debian package:

    make package

## Usage

In addition to normal usage via UDP port 5300 the resolver can be accessed internally via Redis.

Send a request to the queue `dn_query`, e.g.:

    # redis-cli lpush dns_query 5,192.168.1.1,A:eblocker.org
    (integer) 1

In this example:

* 5 is the ID of the request
* 192.168.1.1 is the name server to send the request to.

Receive the response from queue `dns_response:REQID`, where REQID is the ID used in the request:

    # redis-cli lpop dns_response:5
    "{\"responses\":[\"0,A,eblocker.org,174.138.100.168\"],\"log\":[\"1706868661.5324538,192.168.1.1,valid,0.042659066\"]}"
