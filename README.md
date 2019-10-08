## Module Overview

The `wso2/storeforward` module provides a Message Storing Client and a Message Forwarding Service to store and 
forward messages, ensuring reliable delivery of messages.

It allows you to,

1. Decouple message producer and subscriber
2. Enable guaranteed message delivery to an HTTP endpoint
3. Message rate throttling 
4. In order message delivery 
5. Scheduled message delivery 

The Store Forward module makes use of the WSO2 JMS Module (`wso2/jms`) for underlying communication.

**Store Forward Client**

The `storeforward:Client` is used to store messages. The messages are stored into a queue of a message broker. 

**Message Forwarding Processor**

The `storeforward:MessageForwardingProcessor` is used to poll messages from the store (i.e. queue in message broker), and 
forward them reliably to the HTTP endpoint. 

## Compatibility

|                             |           Version           |
|:---------------------------:|:---------------------------:|
| Ballerina Language          |            1.0.1            |

## Getting Started

### Prerequisites

- Download and install [Ballerina](https://ballerinalang.org/downloads/).
- Install a message broker to store messages in a queue. You can download and install 
[Apache ActiveMQ](http://activemq.apache.org/getting-started.html).

### Pull the Module

You can pull the Store forward module from Ballerina Central using the command:

```bash
$ ballerina pull wso2/storeforward
```

## Samples

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
`/services/SimpleStockQuoteService` endpoint. This file should be added to a different project or module from the one which contains the 
`Message Store` service.

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

## Integration patterns 

### 1. Reliable delivery

The connector can be used to forward an HTTP message reliable to a HTTP service. If you need to expose an unreliable HTTP service
in an reliable manner, this connector can be used. Message will not get discarded until it is successfully delivered to the service. 
The poison messages which cannot be processed by the service, can be routed to DLC store and users can manually deal with them. 

### 2. In order message delivery 

This connector stores messages in a queue of a message broker, which keeps FIFO behavior. Hence, the inbound messages are stored
in the order they reached the service. When polling, messages are picked and processed once after the other, where the order
of messages in the queue is kept when delivering to the backend. If a message is failed to process, the processor can be configured
to stop until issue is fixed, so that the order is ensured.

### 3. Message throttling 

Sometimes, there are legacy backend services in the systems, which cannot service inbound requests in a high throughput. they may crash
or go out of resources. If there are spikes in the inbound request rate, which backend service cannot withhold, there is a need to regulate
the message rate. 

Messages can be stored in the incoming rate. Message forwarding rate is governed by following parameters. 

* `pollTimeConfig` - users can configure an interval where forwarding task triggers. Even a cron expression is possible. (i.e `0/2 * * * * ?`)
* `forwardingInterval` - By default this is configured to`0`. It is effective only when `batchSize > 1`. The messages in a 
                       batch will be forwarded to the HTTP service with a delay of `forwardingInterval` between the messages configured in milliseconds. By default `batchSize = 1`. 

### 4. Asynchronous messaging 

By design, messages are not processed in a synchronous manner. Inbound messages are stored and then they are processed. Processing can be scheduled 
so that messages came in are processed later in off-peak hours. Storing service and processing service can be two separate containers. 
These are the semantics of asynchronous message processing. Reliable delivery is added on top of it. Thus, in places where asynchronous messaging
is required, this connector can be used. 

## Extensibility

As the connector is using `JMS` connector, any message broker with the support for `JMS` can be configured for 
reliable messaging. Users need to place third party .jar files into `<BALLERINA_HOME>/bre/lib` directory. 
