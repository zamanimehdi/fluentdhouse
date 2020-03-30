# fluentdhouse
 Fluentd output plugin to ClickHouse and auto shema generation

# installation
step 1- copy plugin to fluentd plugin folder

step 2- clickhouse Active Record required

```
gem install clickhouse-activerecord
```

## How It Works

This plugin takes advantage of ActiveRecord underneath. For `host`, `port`, `database`, `adapter`, `username`, `password`, `socket` parameters, you can think of ActiveRecord's equivalent parameters.

## Configuration

    <match my.rdb.*>
      @type sql
      host rdb_host
      port 3306
      database rdb_database
      adapter mysql2_or_postgresql_or_etc
      username myusername
      password mypassword
      socket path_to_socket
      remove_tag_prefix my.rdb # optional, dual of tag_prefix in in_sql

      <table>
        table table1
        insertmapping 'timestamp,tag'
        # This is the default table because it has no "pattern" argument in <table>
        # The logic is such that if all non-default <table> blocks
        # do not match, the default one is chosen.
        # The default table is required.
      </table>

      <table hello.*> # You can pass the same pattern you use in match statements.
        table table2
        # This is the non-default table. It is chosen if the tag matches the pattern
        # AFTER remove_tag_prefix is applied to the incoming event. For example, if
        # the message comes in with the tag my.rdb.hello.world, "remove_tag_prefix my.rdb"
        # makes it "hello.world", which gets matched here because of "pattern hello.*".
      </table>
      
      <table hello.world>
        table table3
        # This is the second non-default table. You can have as many non-default tables
        # as you wish. One caveat: non-default tables are matched top-to-bottom and
        # the events go into the first table it matches to. Hence, this particular table
        # never gets any data, since the above "hello.*" subsumes "hello.world".
      </table>
    </match>

* **host** RDBMS host
* **port** RDBMS port
* **database** RDBMS database name
* **adapter** RDBMS driver name. You should install corresponding gem before start (mysql2 gem for mysql2 adapter, pg gem for postgresql adapter, etc.)
* **username** RDBMS login user name
* **password** RDBMS login password
* **socket** RDBMS socket path
* **remove_tag_prefix** remove the given prefix from the events. See "tag_prefix" in "Input: Configuration". (optional)

\<table\> sections:

* **table** RDBM table name
* **insertcolumn**: [Required] Record to table schema mapping. The format is consists of `key` values are separated by `,`.
* **primary_key** RDBMS table primary key
* **\<table pattern\>**: the pattern to which the incoming event's tag (after it goes through `remove_tag_prefix`, if given). The patterns should follow the same syntax as [that of \<match\>](https://docs.fluentd.org/configuration/config-file#how-match-patterns-work). **Exactly one \<table\> element must NOT have this parameter so that it becomes the default table to store data**.
