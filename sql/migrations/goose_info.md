

example to use goose to migrate the DB Schema:  
~~~sh
# goose migrate one version up:
goose postgres "postgres://<dbuser>:<password>@localhost:5432/<dbname>" up

# goose migrate one version down:
goose postgres "postgres://<dbuser>:<password>@localhost:5432/<dbname>" down
~~~

from the project folder:  
~~~sh
# goose migrate one version up:
goose -dir sql/migrations postgres "postgres://<user>:<password>@<host:port>/<databae>?sslmode=disable" up

# goose migrate one version down:
goose -dir sql/migrations postgres "postgres://<user>:<password>@<host:port>/<databae>?sslmode=disable" down
~~~