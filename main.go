package main

import (
	"os"

	"github.com/pivotal-cf/replicator/replicator"
)

func main() {
	argParser := replicator.NewArgParser()
	tileReplicator := replicator.NewTileReplicator()

	app := replicator.NewApplication(argParser, tileReplicator)
	err := app.Run(os.Args)
	if err != nil {
		// TODO print error
		os.Exit(1)
	}
}
