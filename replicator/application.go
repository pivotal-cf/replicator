package replicator

type Application struct {
	argParser      argParser
	tileReplicator tileReplicator
}

type ApplicationConfig struct {
	Name   string
	Path   string
	Output string
}

//go:generate counterfeiter -o ./fakes/arg_parser.go --fake-name ArgParser . argParser
type argParser interface {
	Parse([]string) (ApplicationConfig, error)
}

//go:generate counterfeiter -o ./fakes/tile_replicator.go --fake-name TileReplicator . tileReplicator
type tileReplicator interface {
	Replicate(ApplicationConfig) error
}

func NewApplication(argParser argParser, tileReplicator tileReplicator) Application {
	return Application{
		argParser:      argParser,
		tileReplicator: tileReplicator,
	}
}

func (r Application) Run(args []string) error {
	config, err := r.argParser.Parse(args)
	if err != nil {
		return err
	}

	err = r.tileReplicator.Replicate(config)
	if err != nil {
		return err
	}

	return nil
}
