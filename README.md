# Fluentdhouse
 Fluentd output plugin to ClickHouse and automatic construction the structure for columns and tables that do not exist. 
 
# Feature
 *  Use clickhouse db as like nosql as without no worries about the structure of the event entry.
 *  Use bulk insertion for increase event input speed. All the spread insert queries related to specific event types may be routed to a distributed table, packed to chunk and inserted and route to the custom node.
 *  fluentd capabilities for parallel threads and queues.
 In the example below, we will have 100 thread for parallelize outputs and each bulkinsert connection sends a command containing 4000 records. And in less than 10 seconds, each thread will send its events.

```
         <buffer>
		      chunk_limit_records 4000
		      flush_thread_count 100
		      flush_interval 10s
        </buffer>

```

 *  Use the clickhouse buffer engine feature to increase speed.
 *  Automatically routing event to appropriate table and multiple distinct ClickHouse clusters depending on the tag of event. 
  


# installation
step 1- Copy plugin to fluentd plugin folder

step 2- Install the following items 

```
gem install activerecord
gem install clickhouse-activerecord
gem install activerecord-import

```

## How It Works

This plugin takes advantage of ActiveRecord underneath. For `host`, `port`, `database`, `username`, `password` parameters, you can think of ActiveRecord's equivalent parameters.

## Configuration

    <match my.rdb.*>
      @type sql
      host rdb_host
      port 3306
      database rdb_database
      username myusername
      password mypassword
      socket path_to_socket
      remove_tag_prefix my.rdb # optional, dual of tag_prefix in in_sql

      <table>
        table table1
        primary_key IDT
        insertmapping 'timestamp,tag'
      </table>

      <table hello.*> # You can pass the same pattern you use in match statements.
        table table2
        primary_key IDT
      </table>
      
      <table hello.world>
        table table3
        primary_key IDT
      </table>
      
    </match>

* **host** RDBMS host
* **port** RDBMS port
* **database** RDBMS database name
* **username** RDBMS login user name
* **password** RDBMS login password
* **remove_tag_prefix** remove the given prefix from the events. (optional)

\<table\> sections:

* **table** RDBM table name
* **insertcolumn**: [Required] Record to table schema mapping. The format is consists of `key` values are separated by `,`.
* **primary_key** RDBMS table primary key
* **\<table pattern\>**: (This section is not currently active and will be added to the project in the future)the pattern to which the incoming event's tag (after it goes through `remove_tag_prefix`, if given). The patterns should follow the same syntax as [that of \<match\>](https://docs.fluentd.org/configuration/config-file#how-match-patterns-work). Exactly one \<table\> element must NOT have this parameter so that it becomes the default table to store data.
