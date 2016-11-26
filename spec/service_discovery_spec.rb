require 'bundler/setup'

require 'chefspec'
require 'chef/node'

require_relative '../libraries/service_discovery'

describe 'Service Discovery' do

  describe ServiceDiscovery do
    let(:node) do
      node = Chef::Node.new
      node.name 'test-node'
      node.set['cluster'] = 'test-cluster'
      node.set['announced_services'] = Mash.new
      node.chef_environment = 'test'
      node
    end

    let(:ip_finder) { double("Chef::IPFinder").as_null_object }

    let(:search_engine) { double("Chef::Search::Query").as_null_object }

    let(:disco) do
      disco = ServiceDiscovery.new(node)
      disco.ip_finder = ip_finder
      disco.search_engine = search_engine
      disco
    end

    describe '#announce_service' do
      before do
        node.stub(:save)
      end

      it 'announces a service specifying an anddress and port' do
        ip_finder.should_receive(:ip_to_scope) { ['private'] }

        disco.announce_service(:test_service, {
          listening_on: { address: '10.11.12.13', port: 3322 }
        })

        node['announced_services']['test_service']['cluster'].should == 'test-cluster'
        node['announced_services']['test_service']['listening_on'].should have(1).item

        expected = {
          'address' => '10.11.12.13',
          'port' => 3322,
          'socket_type' => 'tcp',
          'scope' => 'private'
        }
        node['announced_services']['test_service']['listening_on'][0].should == expected
      end

      it 'announces a service specifying a url' do
        disco.announce_service(:test_service, {
          listening_on: { url: 'mysql://127.0.0.1:3306', scope: 'private' }
        })

        node['announced_services']['test_service']['listening_on'].should have(1).item

        expected = {
          'address' => '127.0.0.1',
          'port' => 3306,
          'socket_type' => 'tcp',
          'scope' => 'private',
          'protocol' => 'mysql'
        }
        node['announced_services']['test_service']['listening_on'][0].should == expected
      end

      it 'announces a service specifying a url an a public host name' do
        disco.announce_service(:test_service, {
          listening_on: { url: 'mysql://some.host:3306', scope: 'public' }
        })

        node['announced_services']['test_service']['listening_on'].should have(1).item

        expected = {
          'address' => 'some.host',
          'port' => 3306,
          'socket_type' => 'tcp',
          'scope' => 'public',
          'protocol' => 'mysql'
        }
        node['announced_services']['test_service']['listening_on'][0].should == expected
      end

      it 'announces a service listening on all interfaces' do
        addresses = {'node' => ['127.0.0.1'], 'private' => ['10.11.12.13'] }
        ip_finder.should_receive(:find_all) { addresses }

        disco.announce_service(:test_service, {
          listening_on: { address: '0.0.0.0', port: 3306 }
        })

        node['announced_services']['test_service']['listening_on'].should have(2).items

        addresses.each_with_index do |(scope, ips), i|
          expected = {
            'address' => ips.first,
            'port' => 3306,
            'scope' => scope,
            'socket_type' => 'tcp'
          }
          node['announced_services']['test_service']['listening_on'][i].should == expected
        end
      end

      it 'announces a service listening on a unix socket' do
        disco.announce_service(:test_service, {
          listening_on: { address: '/var/lib/mysql.sock', protocol: 'mysql' }
        })

        node['announced_services']['test_service']['listening_on'].should have(1).item

        expected = {
          'address' => '/var/lib/mysql.sock',
          'protocol' => 'mysql',
          'socket_type' => 'unix',
          'scope' => 'node'
        }
        node['announced_services']['test_service']['listening_on'][0].should == expected
      end

      it 'announces a service listening on a private ip scope' do
        ip_finder.should_receive(:find_one) { '10.12.11.13' }
        ip_finder.should_receive(:ip_to_scope) { ['private'] }

        disco.announce_service(:test_service, {
          listening_on: { address: 'private_ipv4', port: 3306, protocol: 'mysql' }
        })

        node['announced_services']['test_service']['listening_on'].should have(1).item

        expected = {
          'address' => '10.12.11.13',
          'port' => 3306,
          'protocol' => 'mysql',
          'socket_type' => 'tcp',
          'scope' => 'private'
        }
        node['announced_services']['test_service']['listening_on'][0].should == expected
      end

      it 'announces a service with multiple listeners' do
        ip_finder.should_receive(:ip_to_scope).with('10.11.12.13') { ['private'] }
        ip_finder.should_receive(:ip_to_scope).with('127.0.0.1') { ['node'] }

        disco.announce_service(:test_service, {
          listening_on: [
            { address: '10.11.12.13', port: 3322, socket_type: 'udp' },
            { address: '127.0.0.1', port: 4444, protocol: 'memcached' }
          ]
        })

        node['announced_services']['test_service']['listening_on'].should have(2).items

        expected0 = {
          'address' => '10.11.12.13',
          'port' => 3322,
          'scope' => 'private',
          'socket_type' => 'udp'
        }
        node['announced_services']['test_service']['listening_on'][0].should == expected0

        expected1 = {
          'address' => '127.0.0.1',
          'port' => 4444,
          'scope' => 'node',
          'socket_type' => 'tcp',
          'protocol' => 'memcached'
        }
        node['announced_services']['test_service']['listening_on'][1].should == expected1
      end

      it 'announces a service in a specific cluster' do
        disco.announce_service(:test_service, { cluster: 'my-cluster' })

        node['announced_services']['test_service']['cluster'].should == 'my-cluster'
      end
    end

    describe "#discover_nodes_for" do
      it 'discovers nodes for a given service' do
        q = [
          "announced_services:test_service",
          "chef_environment:#{node.chef_environment}",
          "announced_services_test_service_cluster:#{node['cluster']}"
        ].join(" AND ")

        nodes = [double, double]
        search_engine.should_receive(:search).with(:node, q).and_yield(nodes[0]).and_yield(nodes[1])

        disco.discover_nodes_for(:test_service).should == nodes
      end

      it 'discovers nodes for a given service excluding self' do
        q = [
          "announced_services:test_service",
          "chef_environment:#{node.chef_environment}",
          "announced_services_test_service_cluster:#{node['cluster']}"
        ].join(" AND ")

        nodes = [node, double(name: 'test-double')]
        search_engine.should_receive(:search).with(:node, q).and_yield(nodes[0]).and_yield(nodes[1])

        resp = disco.discover_nodes_for(:test_service, exclude_self: true)

        resp.should have(1).item
        resp[0].should_not eq(node)
      end

      it 'discovers nodes ignoring the environment' do
        q = [
          "announced_services:test_service",
          "announced_services_test_service_cluster:#{node['cluster']}"
        ].join(" AND ")

        search_engine.should_receive(:search).with(:node, q)

        disco.discover_nodes_for(:test_service, environment_aware: false)
      end

      it 'discovers nodes in the given environment' do
        env = "my-env"
        q = [
          "announced_services:test_service",
          "chef_environment:#{env}",
          "announced_services_test_service_cluster:#{node['cluster']}"
        ].join(" AND ")

        search_engine.should_receive(:search).with(:node, q)

        disco.discover_nodes_for(:test_service, environment: env)
      end

      it 'discovers nodes ignoring the cluster' do
        q = [
          "announced_services:test_service",
          "chef_environment:#{node.chef_environment}",
        ].join(" AND ")

        search_engine.should_receive(:search).with(:node, q)

        disco.discover_nodes_for(:test_service, cluster_aware: false)
      end

      it 'discovers nodes in the given cluster' do
        cluster = 'some-cluster'
        q = [
          "announced_services:test_service",
          "chef_environment:#{node.chef_environment}",
          "announced_services_test_service_cluster:#{cluster}"
        ].join(" AND ")

        search_engine.should_receive(:search).with(:node, q)

        disco.discover_nodes_for(:test_service, cluster: cluster)
      end

      it 'discovers nodes in the given data center' do
        q = [
          "announced_services:test_service",
          "chef_environment:#{node.chef_environment}",
          "announced_services_test_service_cluster:#{node['cluster']}",
          "data_center:#{node['data_center']}"
        ].join(" AND ")

        search_engine.should_receive(:search).with(:node, q)

        disco.discover_nodes_for(:test_service, data_center_aware: true)
      end

      it 'accepts a block to iterate over results' do
        nodes = [double, double]
        search_engine.should_receive(:search).and_yield(nodes[0]).and_yield(nodes[1])

        results = Array.new
        resp = disco.discover_nodes_for(:test_service) { |n| results << n }
        resp.should == results
      end
    end

    describe "#discover_connection_endpoints_for" do
      let(:colo_node) do
        n = Chef::Node.new
        n.name 'colo-node'
        n.set['data_center'] = 'dallas-col01'
        n.set['announced_services']['mysql_server'] = {
          cluster: 'core-db',
          listening_on: [
            { protocol: 'mysql', address: '200.123.43.32', port: 3306, scope: 'public', socket_type: 'tcp' },
            { protocol: 'mysql', address: '192.168.13.112', port: 3306, scope: 'private', socket_type: 'tcp' },
            { protocol: 'mysql', address: '127.0.0.1', port: 3306, scope: 'node', socket_type: 'tcp' },
            { protocol: 'mysql', address: '/var/lib/mysql.sock', scope: 'node', socket_type: 'unix' },
            { protocol: 'memcached', address: '127.0.0.1', port: 4444, scope: 'node', socket_type: 'tcp' }
          ]
        }
        n
      end

      let(:linode_node) do
        n = Chef::Node.new
        n.name 'linode-node'
        n.set['data_center'] = 'linode-newark'
        n.set['cloud'] = {
          provider: 'linode',
          public_ipv4: '50.116.32.219',
          local_ipv4: '192.168.124.149'
        }
        n.set['announced_services']['mysql_server'] = {
          cluster: 'core-db',
          listening_on: [
            { protocol: 'mysql', address: '50.116.32.219', port: 3306, scope: 'public', socket_type: 'tcp' },
            { protocol: 'mysql', address: '192.168.124.149', port: 3306, scope: 'private', socket_type: 'tcp' },
            { protocol: 'mysql', address: '127.0.0.1', port: 3306, scope: 'node', socket_type: 'tcp' },
            { protocol: 'mysql', address: '/var/lib/mysql.sock', scope: 'node', socket_type: 'unix' },
            { protocol: 'memcached', address: '127.0.0.1', port: 4444, scope: 'node', socket_type: 'tcp' }
          ]
        }
        n
      end

      let(:ec2_node1) do
        n = Chef::Node.new
        n.name 'ec2-node1'
        n.set['cloud'] = {
          provider: 'ec2',
          local_ipv4: '10.76.185.175',
          public_ipv4: '50.19.73.95'
        }
        n.set['ec2'] = {
          local_ipv4: '10.76.185.175',
          public_ipv4: '50.19.73.95',
          placement_availability_zone: 'us-east-1b'
        }
        n.set['announced_services']['mysql_server'] = {
          cluster: 'core-db',
          listening_on: [
            { protocol: 'mysql', address: '50.19.73.95', port: 3306, scope: 'public', socket_type: 'tcp' },
            { protocol: 'mysql', address: '10.76.185.175', port: 3306, scope: 'private', socket_type: 'tcp' },
            { protocol: 'mysql', address: '127.0.0.1', port: 3306, scope: 'node', socket_type: 'tcp' },
            { protocol: 'mysql', address: '/var/lib/mysql.sock', scope: 'node', socket_type: 'unix' },
            { protocol: 'memcached', address: '127.0.0.1', port: 4444, scope: 'node', socket_type: 'tcp' }
          ]
        }
        n
      end

      let(:ec2_node2) do
        n = Chef::Node.new
        n.name 'ec2-node2'
        n.set['cloud'] = {
          provider: 'ec2',
          local_ipv4: '10.243.38.46',
          public_ipv4: '54.242.1.22'
        }
        n.set['ec2'] = {
          local_ipv4: '10.243.38.46',
          public_ipv4: '54.242.1.22',
          placement_availability_zone: 'us-east-1b'
        }
        n.set['announced_services']['mysql_server'] = {
          cluster: 'core-db',
          listening_on: [
            { protocol: 'mysql', address: '54.242.1.22', port: 3306, scope: 'public', socket_type: 'tcp' },
            { protocol: 'mysql', address: '10.243.38.46', port: 3306, scope: 'private', socket_type: 'tcp' },
            { protocol: 'mysql', address: '127.0.0.1', port: 3306, scope: 'node', socket_type: 'tcp' },
            { protocol: 'mysql', address: '/var/lib/mysql.sock', scope: 'node', socket_type: 'unix' },
            { protocol: 'memcached', address: '10.243.38.46', port: 4450, scope: 'private', socket_type: 'tcp' },
          ]
        }
        n
      end

      let(:ec2_node3) do
        n = Chef::Node.new
        n.name 'ec2-node3'
        n.set['cloud'] = {
          provider: 'ec2',
          local_ipv4: '10.204.39.241',
          public_ipv4: '67.202.59.238',
        }
        n.set['ec2'] = {
          local_ipv4: '10.204.39.241',
          public_ipv4: '67.202.59.238',
          placement_availability_zone: 'us-west-1a'
        }
        n.set['announced_services']['mysql_server'] = {
          cluster: 'core-db',
          listening_on: [
            { protocol: 'mysql', address: '67.202.59.238', port: 3306, scope: 'public', socket_type: 'tcp' },
            { protocol: 'mysql', address: '10.204.39.241', port: 3306, scope: 'private', socket_type: 'tcp' },
            { protocol: 'mysql', address: '127.0.0.1', port: 3306, scope: 'node', socket_type: 'tcp' },
            { protocol: 'mysql', address: '/var/lib/mysql.sock', scope: 'node', socket_type: 'unix' },
            { protocol: 'memcached', address: '127.0.0.1', port: 4444, scope: 'node', socket_type: 'tcp' }
          ]
        }
        n
      end

      before do
        node.set['announced_services']['mysql_server'] = {
          cluster: 'core-db',
          listening_on: [
            { protocol: 'mysql', address: 'some.host', port: 3306, scope: 'public', socket_type: 'tcp' },
            { protocol: 'mysql', address: '10.12.120.11', port: 3306, scope: 'private', socket_type: 'tcp' },
            { protocol: 'mysql', address: '127.0.0.1', port: 3306, scope: 'node', socket_type: 'tcp' },
            { protocol: 'mysql', address: '/var/lib/mysql.sock', scope: 'node', socket_type: 'unix' }
          ]
        }
      end

      it 'discovers connection endpoints for service' do
        nodes = [ec2_node1, ec2_node2, ec2_node3]
        disco.node = ec2_node1

        disco.should_receive(:discover_nodes_for)
          .with(:mysql_server, {cluster: 'core-db', data_center_aware: true})
          .and_return(nodes)

        endpoints = disco.discover_connection_endpoints_for(:mysql_server, {
          cluster: 'core-db',
          data_center_aware: true,
          require: { socket_type: 'tcp', protocol: 'mysql' },
          prefer: { port: 3306  }
        })

        endpoints.should have(3).items
        endpoints.map{|e| e[:scope] }.should == %w(node private public)
        endpoints.map{|e| e[:socket_type] == 'tcp'}.all?.should be_true
        endpoints.map{|e| e[:protocol] == 'mysql'}.all?.should be_true
      end

      it 'discovers unix socket connection endpoint for service on local node' do
        endpoints = disco.discover_connection_endpoints_for(:mysql_server, {
          node: node,
          require: { socket_type: 'unix', protocol: 'mysql' }
        })

        endpoints.should have(1).item
        endpoints[0][:scope].should == 'node'
        endpoints.map{|e| e[:socket_type] == 'unix'}.all?.should be_true
        endpoints.map{|e| e[:protocol] == 'mysql'}.all?.should be_true
      end

      it 'discovers unix socket connection endpoint for service on local node' do
        endpoints = disco.discover_connection_endpoints_for(:mysql_server, {
          node: node,
          require: { scope: 'public', protocol: 'mysql' }
        })

        endpoints.should have(1).item
        endpoints[0][:scope].should == 'public'
        endpoints.map{|e| e[:socket_type] == 'tcp'}.all?.should be_true
        endpoints.map{|e| e[:protocol] == 'mysql'}.all?.should be_true
        endpoints.map{|e| e[:address] == 'some.host'}.all?.should be_true
      end

      it 'discovers connection endpoints for a certain protocol' do
        nodes = [ec2_node1, ec2_node2, ec2_node3]
        disco.node = ec2_node1

        disco.should_receive(:discover_nodes_for)
          .with(:mysql_server, {})
          .and_return(nodes)

        endpoints = disco.discover_connection_endpoints_for(:mysql_server, {
          require: { socket_type: 'tcp', protocol: 'memcached' }
        })

        endpoints.should have(2).items
        endpoints.map{|e| e[:scope] }.should == %w(node private)
        endpoints.map{|e| e[:socket_type] == 'tcp'}.all?.should be_true
        endpoints.map{|e| e[:protocol] == 'memcached'}.all?.should be_true
      end
    end

  end


  describe ServiceDiscovery::DSL do
    class Recipe < Struct.new(:node)
    end

    let(:node) do
      double
    end

    let(:recipe) do
      recipe = Recipe.new(node)
      recipe.extend ServiceDiscovery::DSL
      recipe
    end

    describe 'announce_service' do
      it 'is included in the recipe' do
        recipe.respond_to?(:announce_service).should be_true
      end

      it 'delegates to a ServiceDiscovery instance' do
        disco = double
        ServiceDiscovery.should_receive(:new).with(node) { disco }
        disco.should_receive(:announce_service)

        recipe.announce_service("test-service", {})
      end
    end

    describe 'discover_nodes_for' do
      it 'is included in the recipe' do
        recipe.respond_to?(:discover_nodes_for).should be_true
      end

      it 'delegates to a ServiceDiscovery instance' do
        disco = double
        ServiceDiscovery.should_receive(:new).with(node) { disco }
        disco.should_receive(:discover_nodes_for)

        recipe.discover_nodes_for("test-service", {})
      end
    end

    describe 'discover_connection_endpoints_for' do
      it 'is included in the recipe' do
        recipe.respond_to?(:discover_connection_endpoints_for).should be_true
      end

      it 'delegates to a ServiceDiscovery instance' do
        disco = double
        ServiceDiscovery.should_receive(:new).with(node) { disco }
        disco.should_receive(:discover_connection_endpoints_for)

        recipe.discover_connection_endpoints_for("test-service", {})
      end
    end

  end
end
