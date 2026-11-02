# Contributing

Bug reports, doc fixes and small improvements are welcome. For anything bigger, open an issue first so we can agree on the approach before you spend time on it.

## Run the checks

```bash
terraform fmt -check -recursive
cd AWS/modules/s3_lifecycle && terraform init -backend=false && terraform validate
```

No cloud credentials are needed.

## Pull requests

Keep each PR to one change. Say what you ran to check it. CI has to pass before merge.

Issues labelled "good first issue" are a good place to start.
