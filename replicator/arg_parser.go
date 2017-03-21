package replicator

import (
	"errors"
	"flag"
	"strings"
)

type ArgParser struct{}

func NewArgParser() ArgParser {
	return ArgParser{}
}

func (ArgParser) Parse(args []string) (ApplicationConfig, error) {
	cfg := ApplicationConfig{}

	flagSet := flag.NewFlagSet("replicator", flag.ExitOnError)
	flagSet.StringVar(&cfg.Name, "name", "", "suffix for tile name")
	flagSet.StringVar(&cfg.Path, "path", "", "path to source tile")
	flagSet.StringVar(&cfg.Output, "output", "", "desired path for the duplicated tile")
	flagSet.Parse(args)

	var errMsgs []string

	if cfg.Name == "" {
		errMsgs = append(errMsgs, "--name is a required argument")
	}

	if cfg.Path == "" {
		errMsgs = append(errMsgs, "--path is a required argument")
	}

	if cfg.Output == "" {
		errMsgs = append(errMsgs, "--output is a required argument")
	}

	if len(errMsgs) != 0 {
		return cfg, errors.New(strings.Join(errMsgs, ", "))
	}

	return cfg, nil
}
