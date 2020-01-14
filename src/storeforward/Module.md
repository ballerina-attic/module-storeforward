Provides guaranteed message delivery in Ballerina.

# Module Overview

The `wso2/storeforward` module provides a Message Storing Client and a Message Forwarding Service to store and 
forward messages, ensuring reliable delivery of messages.

It allows you to,

1. Decouple message producer and subscriber
2. Enable guaranteed message delivery to an HTTP endpoint
3. Message rate throttling 
4. In order message delivery 
5. Scheduled message delivery 

The Store Forward module utilizes the WSO2 JMS Module (`wso2/jms`) for underlying communication.

**Store Forward Client**

The `storeforward:Client` is used to store messages. The messages are stored in a queue of a message broker. 

**Message Forwarding Processor**

The `storeforward:MessageForwardingProcessor` is used to poll messages from the store (i.e. queue in message broker), 
and forward them reliably to the HTTP endpoint. 

## Compatibility

|  Ballerina Language Version |   StoreForward Module Version   |
|:---------------------------:|:-------------------------------:|
|            1.0.x            |              0.9.x              |
|            1.1.x            |             0.10.x              |

## Sample

Requests received to integration service should be stored in the queue using the `storeforward:Client`. Then 
`messageStore:MessageForwardingProcessor` is used to poll messages from the store and forward them reliably to HTTP endpoint.

Before getting started with the samples below, make sure you have a message broker instance up and running.
To enable connecting to ActiveMQ message broker, create `lib` directory in your Ballerina project and add the 
following `.jar` files from `[ACTIVEMQ-HOME]/lib` directory. Then add the library references to the `Ballerina.toml` file as below:

```ballerina
[platform]
target = "java8"

  [[platform.libraries]]
  module = "listener"
  path = "./lib/activemq-client-5.15.5.jar"

  [[platform.libraries]]
  module = "listener"
  path = "./lib/geronimo-j2ee-management_1.1_spec-1.0.1.jar"

  [[platform.libraries]]
  module = "listener"
  path = "./lib/hawtbuf-1.11.jar"
```

Then add the `stockQuote` service which will store the messages received at the `/stock-management/quotes` 
endpoint, in the message queue `stock_orders`. 

**Message Store**

```ballerina
import ballerina/http;
import wso2/storeforward;

@http:ServiceConfig { basePath: "/stock-management" }
service stockQuote on new http:Listener(8080) {

    @http:ResourceConfig {
        methods: ["POST"],
        path: "/quotes"
    }
    resource function placeOrder(http:Caller caller, http:Request request) returns error? {
        // Configure message store to publish stock orders
        storeforward:MessageStoreConfiguration storeConfig = {
            messageBroker: "ACTIVE_MQ",
            providerUrl: "tcp://localhost:61616",
            queueName: "stock_orders"
        };

        // Initialize client to store the message
        storeforward:Client storeClient = check new storeforward:Client(storeConfig);
        var result = storeClient->store(request);

        // Respond back to the caller based on the result
        if (result is error) {
            check caller->respond("Stock order placement failed.");
        } else {
            check caller->respond("Stock order placed successfully.");
        }
    }
}
```

Next add the `Message Processor` which will poll for messages in the message queue and forward any new messages to the 
`/services/SimpleStockQuoteService` endpoint. 

**Message Processor**

```ballerina
import ballerina/http;
import ballerina/log;
import wso2/storeforward;

public function main(string... args) {
    // Configure message store to consume stock orders
    storeforward:MessageStoreConfiguration storeConfig = {
            messageBroker: "ACTIVE_MQ",
            providerUrl: "tcp://localhost:61616",
            queueName: "stock_orders"
        };

    // Configure processor to send the message to the backend every second
    storeforward:ForwardingProcessorConfiguration processorConfig = {
        storeConfig: storeConfig,
        HttpEndpointUrl: "http://localhost:9000/services/SimpleStockQuoteService",
        pollTimeConfig: 1000,
        retryInterval: 3000,
        maxRedeliveryAttempts: 5
    };

    // Initialize and start processor to run periodically
    var stockOrderProcessor = new storeforward:MessageForwardingProcessor(processorConfig, handleResponse);
    if (stockOrderProcessor is error) {
        log:printError("Error while initializing message processor.", err = stockOrderProcessor);
        panic stockOrderProcessor;
    } else {
        var isStart = stockOrderProcessor. start();
        if (isStart is error) {
            panic isStart;
        } else {
            stockOrderProcessor.keepRunning();
        }
    }
}

// Process the response received by stock quote service 
function handleResponse(http:Response response) {
    int statusCode = response.statusCode;
    if (statusCode == 200) {
        log:printInfo("Stock order persisted sucessfully.");
    } else {
        log:printError("Error status code " + statusCode.toString() + " received from the stock quote service ");
    }
}
``` 

## Module Features

## Storing messages

### 1. Can configure any message broker

This is possible as the Store forward connector uses the JMS connector for underlying communication. It supports any 
message broker with `JMS` support. Currently, the connector is tested with Active MQ, IBM MQ and WSO2 MB message brokers. 

### 2. Store messages reliably

If storing a message failed, the connector will try to store it to the same message store a few times before giving up. 
The store connector will try to reinitialize the connection to the broker and try to send the message over JMS. If 
this is a transient connection issue that occurred while storing the message, this feature can recover from that situation. 

When retrying, users can configure

* `interval` - Time interval to attempt connecting to broker (seconds). Each time this time gets multiplied by 
`backOffFactor` until `maxWaitInterval` is reached
* `backOffFactor` - Interval for retrying will increase per iteration by this factor
* `maxWaitInterval` - Maximum value for '`interval` 
* `count` - Specify (-1) to retry infinitely. Otherwise, this will be the maximum number of retry attempts before giving up.

If failed to store the message after all retries, `store` method will return an error.
 
### 3. Configure a secondary message store

If all retry attempts to store the message in the primary store have failed, and if a secondary store is configured, store 
connector will try to store the message in the secondary store. This can be a separate queue on the same broker. However, 
configuring a queue on a different broker instance will give more reliability in case the primary broker is not responding.
Secondary store can also have resiliency parameters. 

If failed to store the message in both primary and secondary stores after all retry attempts, `store` method will return an error.

>NOTE: you can have another `secondary` store for the configured secondary store as well. This will build a chain of stores
to retry storing. 

### 4. Failover of brokers

JMS broker has the failover feature, in which if the primary broker is not reachable, JMS implementation will try the next broker
in the fail-over chain. As the connector uses JMS, this feature is inherited. 

Example: [Failover feature when using ActiveMQ](https://activemq.apache.org/failover-transport-reference)
         [Failover feature when using WSO2 MB](https://docs.wso2.com/display/MB320/Handling+Failover)

## Forwarding messages

### 1. Forwarding messages to HTTP services. Configure SSL, timeouts, keep-alive, chunking etc 

The `MessageForwardingProcessor` can be configured to invoke secured services using SSL/TLS or Oauth tokens. Any 
configuration related to [HTTP Client of Ballerina](https://v1-0-0-alpha.ballerina.io/learn/api-docs/ballerina/http/records/ClientEndpointConfig.html) 
can be provided. 

Example config: 

```ballerina
    http:ServiceEndpointConfiguration endpointConfig = {
        secureSocket: {
            trustStore: {
                path: "${ballerina.home}/bre/security/trustStore",
                password: "ballerina"
            }
        },
        timeoutMillis: 70000
    };
    storeforward:ForwardingProcessorConfiguration myProcessorConfig = {
        HttpEndpointUrl: "http://127.0.0.1:9095/testservice/test",
        HttpOperation: http:HTTP_POST,
        HttpEndpointConfig: endpointConfig
        ...
    };
```

### 2. Resiliency in forwarding messages to an HTTP service

When forwarding messages user can configure,

* `retryInterval` - Interval between two retries in milliseconds
* `maxRedeliveryAttempts` - Maximum number of times to retry

Note that if `maxRedeliveryAttempts` exceeded when trying to forward a message, that message is considered as a forwarding fail message.
According to `forwardingFailAction` this message will either be dropped or routed to another store. Also if you configured `retryConfig`
under httpClient config set at `HttpEndpointConfig`, it will be overridden by these values. 

Sample config : Retry 5 times with 3 second interval 

```ballerina
    storeforward:ForwardingProcessorConfiguration myProcessorConfig = {
        storeConfig: myMessageStoreConfig,
        HttpEndpointUrl: "http://127.0.0.1:9095/testservice/test",
        pollTimeConfig: "0/2 * * * * ?",
        retryInterval: 3000,
        maxRedeliveryAttempts: 5
    };
```

### 3. Control message forwarding rate

Message forwarding rate is controlled by following parameters.

* `pollTimeConfig` - Interval messages should be polled from the broker (milliseconds) or cron expression for polling task (i.e. `0/2 * * * * ?`)
* `forwardingInterval` - By default this is configured to `0`. It is effective only when `batchSize > 1`. The messages 
in a batch will be forwarded to the HTTP service with a delay of `forwardingInterval` between the messages configured 
in milliseconds. By default `batchSize = 1`. 

>Note : message preprocess delay and response handling delay will also get added and effect the overall forwarding rate. 
>This is because messages are processed one after the other. 

Sample config: Forward a message once two seconds

```ballerina
    storeforward:ForwardingProcessorConfiguration myProcessorConfig = {
        storeConfig: myMessageStoreConfig,
        HttpEndpointUrl: "http://127.0.0.1:9095/testservice/test",
        pollTimeConfig: "0/2 * * * * ?",
        retryInterval: 3000,
        maxRedeliveryAttempts: 5
    };
```

Sample config: Forward a message once every 100ms

```ballerina
    storeforward:ForwardingProcessorConfiguration myProcessorConfig = {
        storeConfig: myMessageStoreConfig,
        HttpEndpointUrl: "http://127.0.0.1:9095/testservice/test",
        pollTimeConfig: 100,
        retryInterval: 3000,
        maxRedeliveryAttempts: 5
    };
```

### 4. Scheduled message forwarding

When you need to trigger message forwarding at a specific time of the day, or at a specific
time every day or every week, you can specify a cron. 

There is a question how many messages to process once forwarding is triggered because there can be 
millions of messages on the store. You can specify that by `batchSize` (default = 1). The interval between 
two message forwards is configured by `forwardingInterval` (default = 0). 

>Note: When `batchSize` is configured to -1 the processor will poll messages until the store becomes empty. When there is
       no messages in store, processing will get stopped until next time it is triggered as per the cron specified.

On how to construct cron expressions, refer [here](http://www.quartz-scheduler.org/documentation/quartz-2.3.0/tutorials/crontrigger.html). 

Sample config: Trigger at 3.45 P.M everyday and forward all messages on store, one message per 3 seconds. 

```ballerina
    storeforward:ForwardingProcessorConfiguration myProcessorConfig = {
        storeConfig: myMessageStoreConfig,
        HttpEndpointUrl: "http://127.0.0.1:9095/testservice/test",
        pollTimeConfig: "0 45 15 * * ?",
        retryInterval: 3000,
        maxRedeliveryAttempts: 5,
        batchSize: -1,
        forwardingInterval: 3000
    };
```

Sample config: Fire every minute starting at 2pm and ending at 2:59pm, every day. At every minute, forward 30 messages max with an interval
               of one second between each message forward. 

```ballerina
    storeforward:ForwardingProcessorConfiguration myProcessorConfig = {
        storeConfig: myMessageStoreConfig,
        HttpEndpointUrl: "http://127.0.0.1:9095/testservice/test",
        pollTimeConfig: "0 * 14 * * ?",
        retryInterval: 3000,
        maxRedeliveryAttempts: 5,
        batchSize: 30,
        forwardingInterval: 1000
    };
```

### 5. Consider responses with configured HTTP status codes as forwarding failures

Sometimes, even if the backend HTTP service sent a response, we need to consider it as a failure. For an example, if
HTTP status code is 500 or 404, it is in fact not processed by the service. To cater the cases, you can specify a set of
status codes which message processor should consider as a forwarding failure, and hence retry forwarding again. 

Sample config: 

```ballerina
    storeforward:ForwardingProcessorConfiguration myProcessorConfig = {
        storeConfig: myMessageStoreConfig,
        HttpEndpointUrl: "http://127.0.0.1:9095/testservice/test",
        pollTimeConfig: "0/2 * * * * ?",
        retryInterval: 3000,
        maxRedeliveryAttempts: 5,
        retryHttpStatusCodes:[500,400]
    };
```

### 6. Different actions upon a message forwarding failure

Depending on the use-case, users will need to do either of the following when message processor failed to forward it to the
HTTP service. 

* `DROP` - Drop the message and continue with the next message on the store
* `DEACTIVATE` - Stop message processing further. User will need to manually remove the message or fix the issue and 
restart message polling service. 
* `DLC_STORE` - Move the failing message to a configured message store and continue with the next message. Later user 
can deal with the messages in the DLC store manually. 

By default, the behavior is to `DROP`. 

Sample config: Try to forward each message 5 times. If there is a failure, deactivate the processor. 

```ballerina
    storeforward:ForwardingProcessorConfiguration myProcessorConfig = {
        storeConfig: myMessageStoreConfig,
        HttpEndpointUrl: "http://127.0.0.1:9095/testservice/test",
        pollTimeConfig: "0/2 * * * * ?",
        retryInterval: 3000,
        maxRedeliveryAttempts: 5,
        forwardingFailAction: storeforward:DEACTIVATE
    };
```

### 7. Ability to configure a Dead Letter Store

Dead Letter Store is a pattern where the message processing will set aside the messages those failed to store. Those messages
are moved to a separate store and the user can deal with them manually later. 

Sample config: Try to forward each message 5 times. If there is a failure, move the message to queue `myDLCStore`. 

```Ballerina
    storeforward:MessageStoreConfiguration dlcMessageStoreConfig = {
        messageBroker: "ACTIVE_MQ",
        providerUrl: "tcp://localhost:61616",
        queueName: "myDLCStore"
    };

    storeforward:Client dlcStoreClient = new storeforward:Client(dlcMessageStoreConfig);

    storeforward:ForwardingProcessorConfiguration myProcessorConfig = {
        storeConfig: myMessageStoreConfig,
        HttpEndpointUrl: "http://127.0.0.1:9095/testservice/test",
        pollTimeConfig: "0/2 * * * * ?",
        retryInterval: 3000,
        maxRedeliveryAttempts: 5,
        forwardingFailAction: storeforward:DLC_STORE,
        DLCStore: dlcStoreClient 
    };
```

### 8. Pre-process message before forwarding to the backend service

By design, message processor will reconstruct the HTTP request that is stored in the message store and forward to the service.
However, sometimes there is a requirement to modify the HTTP request before sending it out to an HTTP service (i.e a heavy transformation).
A workaround for this will be to do the transformation prior to storing the message and store it, but if it is heavy, user might 
want to store what is inbound and do the transformation at message processing with a controlled forwarding rate. 

In such cases, user can define a function with the logic to do the pre-processing and configure it as follows.

```ballerina
function preProcessRequestFunction(http:Request request) {
    request.setHeader("company", "WSO2");
}
var myMessageProcessor = new storeforward:MessageForwardingProcessor(myProcessorConfig, 
            handleResponseFromBE, preProcessRequest = preProcessRequestFunction);
...
```

>Note The time taken to pre-process the message will get added to the message forwarding interval. 

### 9. Process response received by backend service after the forward

User need to do some operation on the response received by the backend service. This may be calling
another service with the response, or store details of the response in a database.  User can define a function with the 
logic to handle the response and configure it in the processor.

```ballerina
function handleResponseFromBE(http:Response resp) {
    var payload = resp.getJsonPayload();
    if(payload is json) {
        log:printInfo("Response received " + "Response status code= "+ resp.statusCode + ": "+ payload.toString());
    } else {
        log:printError("Error while getting response payload ", err=payload);
    }
}
var myMessageProcessor = new storeforward:MessageForwardingProcessor(myProcessorConfig, handleResponseFromBE);
...
```

>Note The time taken to process the response message will get added to the message forwarding interval. 
