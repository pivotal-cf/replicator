# Replicator

A program the replicates tiles

![replicatin stuff](http://3.bp.blogspot.com/-YKsAqy5JSlc/VR_FTmSmocI/AAAAAAAADfc/IpJNTaI2pCc/s1600/replicating-irrational-exuberance.gif)

## Usage

An operator can use the `replicator` to create new copies of the Isolation Segment or Windows Runtime tiles. To do so, you will need the following:

1. a [name](#naming) for the copy
1. a copy of the original tile, downloaded from PivNet
1. a location to put the copy

With these things in hand, you can run the following command to replicate the tile:

```
$ replicator \
    -name "blue" \
    -path /absolute/path/to/tile.pivotal \
    -output /absolute/path/to/output.pivotal
```

## Naming

Naming your copy is important. You should pick a name that describes the tiles use.
There are a couple of constraints on tile names:

1. the name may only contain alphanumeric characters, `-`, `_`, and spaces
1. the name must be 10 characters or less
