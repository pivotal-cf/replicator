package main

import "os"

func main() {
	app := replicator.NewReplicator()
	err := app.Run(os.Args)
	if err != nil {
		// TODO print error
		os.Exit(1)
	}
}
