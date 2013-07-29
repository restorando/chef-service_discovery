# service_discovery Cookbook

`service_discovery` is a library cookbook aiming at solving the systems integration problem with Chef. It allows you to announce services and discover them from client nodes. It uses the Chef server as a discovery mechanism and supports publishing metadata like port, host, protocol, data center, cluster, etc.

## Usage

### Announcing services

You can announce services using the DSL method `announce_service`. It requires a service name and a hash of parameters that specify where to find it and how to connect to it.

The service name can be any string or symbol. The expected parameters are the following:

- `cluster`: The name of the cluster the service belongs to. If ommitted, it will default to the value of `node['cluster']`.
- `data_center`: The data center where the node is hosted. If omitted, it will default to the value of `node['data_center']`.
- `environment`: The environment where the service is running. If omitted, it will default to the value of `node.chef_environment`.
- `listening_on`: This is a required parameter. It is an array of hashes where each hash represents a connection endpoint to the service. Each endpoint can be described with the following properties:
	* `address`: It can be an IP address or a hostname. It defaults to `0.0.0.0`.
  * `scope`: The network scope the services is listening on. It can be `node` (lookback interface), `private` (private network), or `public` (public internet). If the `address` is provided, the `scope` is guessed automatically. Otherwise, the `address` will be guessed with the given `scope`.
  * `port`: A tcp or udp port number.
  * `socket_type`: It can be tcp, udp, or unix. Defaults to tcp.
  * `protocol`: A protocol the service understands like http, amqp, smtp, mysql, etc.
  * `url`: A connection url like `mysql://user:pass@host:port`. The url will be parsed and used to fill the rest of the properties.

#### Examples

Announcing a Redis master instance with a connection url:

```ruby
announce_service :redis_master, {
  cluster: 'my-app',
  listening_on: [
    { url: "redis://#{node['ipaddress']}:6379" }
  ]
}
```

Announcing a redis slave instance with connection parameters:

```ruby
announce_service :redis_slave, {
  cluster: 'my-app',
  listening_on: [{
    scope: :private_ipv4,
    port: 6379,
    protocol: 'redis'
  }]
}
```

Announcing a RabbitMQ server:

```ruby
announce_service :rabbitmq, {
  listening_on: [{
    protocol: 'amqp',
    address: node['rabbitmq']['address'] || '0.0.0.0',
    port: node['rabbitmq']['port'] || 5672
  }, {
    protocol: 'amqps',
    address: node['rabbitmq']['address'] || '0.0.0.0',
    port: node['rabbitmq']['ssl_port'] || 5671
  }, {
    protocol: 'https',
    address: node['rabbitmq']['management']['host'] || '0.0.0.0',
    port: node['rabbitmq']['management']['port'] || 15672
  }]
}
```

Announcing a MySQL server:

```ruby
announce_service :mysql_master, {
  listening_on: [
    { protocol: 'mysql', address: '/var/lib/mysql/mysql.sock', socket_type: 'unix' },
    { protocol: 'mysql', address: '127.0.0.1', port: 3306 },
    { url: 'mysql://10.30.100.42:3306' },
    { protocol: 'mysql', address: '200.12.132.11', port: 3306, scope: 'public' },
    { protocol: 'memcached', address: 'private_ipv4', port: 4432 }
  ],
  cluster: "my-db-cluster",
  data_center: 'nydc01',
  environment: 'qa'
}
```

### Discovering services

There are two DSL methods to discover services, `dicover_nodes_for` and `discover_connection_endpoints_for`.

`discover_nodes_for` gives you a list of nodes where the service you're looking for is running. It accepts two parameters, a service id and a hash of properties to scope the search. These properties are:

- `environment_aware`: It's a boolean parameter that scopes the search to a given environment. By default, `node.chef_environment`. Defaults to `true`.
- `environment`: The environment to scope the search.
- `cluster_aware`: It's a boolean parameter that scopes the search to a given cluster. By default, `node['cluster']`. Defaults to `true`.
- `cluster`: The cluster to scope the search.
- `data_center_aware`: It's a boolean parameter that scopes the search to a given data center. By default, `node['data_center']`. Defaults to `false`.
- `data_center`: The data center to scope the search.
- `exclude_self`: It's a boolean parameter to exlcude the current node from results in case it appears in the search.

`discover_connection_endpoints_for` gives you a list of endpoints to connect to. It accepts the same parameters as `discover_nodes_for`, and a few additions:

- `node`: Scopes the search to the given node.
- `nodes`: Scopes the search to a list of nodes.
- `require`: It's a hash of required attributes for the endpoints, like `protocol`, `port`, `scope`, etc.

It will also find the closet endpoints to the node performing the search. For instance, let's say you have a service `foo` running in nodes `A`, `B`, `C` and listing on all the available interfaces. Nodes `A` and `B` are in the same network, node `C` is not.
If you perform the search from node `A` you will get endpoints for loopback in `A`, private ip address in `B` and public ip in `C`.

#### Examples

Discover nodes for a mysql service in a certain environment and cluster:

```ruby
nodes = discover_nodes_for :mysql_server, exclude_self: true, environment: 'qa', cluster: 'my-db-cluster'
```

Get a list of host and port pairs for a mysql service with memcached endpoints:

```ruby
host_port_pair = discover_connection_endpoints_for(:mysql_server, {
                   cluster: 'my-db-cluster',
                   data_center_aware: true,
                   data_center: 'nydc01',
                   require: { protocol: 'memcached', socket_type: 'tcp' }
                 }).map do |endpoint|
  [endpoint[:address], endpoint[:port] || 3306].join(":")
end
```

Get a list of endpoints to connect to a rabbitmq broker:

```ruby
discover_connection_endpoints_for :rabbitmq, {
  cluster: 'amqp01',
  require: { protocol: 'amqp' }
}
```

Get a list of endpoints for the rabbitmq management interface:

```ruby
discover_connection_endpoints for :rabbitmq, {
  cluster: 'amqp01',
  require: { protocol: 'https', port: 15672 }
}
```

## Similar projects

This cookbook was inspired by:

- [Silverware](https://github.com/infochimps-labs/ironfan-pantry/tree/master/cookbooks/silverware)
- [Discovery](https://github.com/hw-cookbooks/discovery)


## License

Copyright (c) 2013 Restorando

MIT License

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
