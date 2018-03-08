package main

import (
	"log"
	"os"

	"github.com/pivotal-cf/replicator/replicator"
)

func main() {
	logger := log.New(os.Stdout, "", 0)

	argParser := replicator.NewArgParser()
	tileReplicator := replicator.NewTileReplicator(logger)

	app := replicator.NewApplication(argParser, tileReplicator)
	err := app.Run(os.Args[1:])
	if err != nil {
		log.Fatalf("error: %s", err)
	}
}
