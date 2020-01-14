// Copyright (c) 2019 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerina/log;
import ballerina/math;
import ballerina/runtime;
import ballerina/task;
import wso2/jms;


# Definition of forwarding Processor object. It polls messages from the configured Message Broker queue
# and forwards messages to the configred HTTP endpoint with reliability.
public type MessageForwardingProcessor object {

    //TODO: remove after (ballerina-lang/issues/16201)
    boolean active;

    ForwardingProcessorConfiguration processorConfig;

    // Objects related to JMS connection
    jms:Connection jmsConnection;
    jms:Session jmsSession;
    jms:MessageConsumer messageConsumer;

    // Task driving the message polling from the broker and forward
    task:Scheduler? messageForwardingTask = ();

    # Initialize `MessageForwardingProcessor` object. This will create necessary
    # connnections to the configured message broker and configured backend. Polling 
    # of messages is not started until `start` is called. 
    # 
    # + processorConfig - `ForwardingProcessorConfiguration` processor configuration 
    # + handleResponse  - `function (http:Response resp)` lambda to process the response from HTTP BE
    #                      after forwarding the request by processor
    # + preProcessRequest - `function(http:Request requst)` lambda to process the request before forwarding to the backend
    # + return - `error` if there is an issue initializing processor (i.e. connection issue with broker)
    public function __init(ForwardingProcessorConfiguration processorConfig,
    function(http:Response resp) handleResponse, function(http:Request request)? preProcessRequest = ()) returns error? {
        self.active = true;
        self.processorConfig = processorConfig;

        MessageStoreConfiguration storeConfig = processorConfig.storeConfig;
        string initialContextFactory = getInitialContextFactory(storeConfig.messageBroker);
        string acknowledgementMode = CLIENT_ACKNOWLEDGE;
        string queueName = storeConfig.queueName;

        // If retry config is not set, set one with defaults
        if(storeConfig?.retryConfig == ()) {
            storeConfig.retryConfig = {
                count: -1,  // Infinite retry until success
                interval: 5,
                backOffFactor: 1.5,
                maxWaitInterval: 60
            };
        }

        // Init connection to the broker
        var consumerInitResult = check trap initializeConsumer(storeConfig);
        var [connection, session, consumer] = consumerInitResult;
        self.jmsConnection = connection;
        self.jmsSession = session;
        self.messageConsumer = consumer;

        // Init HTTP endpoint
        http:Client httpClient = check self.initializeHTTPClient(processorConfig);

        // Check if a cron is mentioned in config. If so, it gets priority
        string | int currentpollTimeConfig = processorConfig.pollTimeConfig;
        if (currentpollTimeConfig is string) {
            self.messageForwardingTask = new({appointmentDetails: currentpollTimeConfig});
        } else {
            self.messageForwardingTask = new({intervalInMillis: currentpollTimeConfig});
        }

        int[] retryHttpCodes = [];
        int[]? retryHttpCodesFromConfig = processorConfig["retryHttpStatusCodes"];
        if (retryHttpCodesFromConfig is int[]) {
            retryHttpCodes = retryHttpCodesFromConfig;
        }

        // Create a record with objects required for the polling service
        PollingServiceConfig pollingServiceConfig = {
            messageConsumer: self.messageConsumer,
            queueName: queueName,
            httpClient: httpClient,
            httpEP: processorConfig.HttpEndpointUrl,
            HttpOperation: processorConfig.HttpOperation,
            retryHttpCodes: retryHttpCodes,
            forwardingFailAction: processorConfig.forwardingFailAction,
            batchSize: processorConfig.batchSize,
            forwardingInterval: processorConfig.forwardingInterval,
            onMessagePollingFail: onMessagePollingFail(self),
            onDeactivate: onDeactivate(self),
            preProcessRequest: preProcessRequest,
            handleResponse: handleResponse,
            DLCStore: processorConfig["DLCStore"]
        };

        // Attach the task work
        task:Scheduler? task = self.messageForwardingTask;
        if (task is task:Scheduler) {
            var assignmentResult = task.attach(messageForwardingService,  attachment = pollingServiceConfig);
            if (assignmentResult is error) {
                log:printError("Error when attaching service to the message processor task ", err = assignmentResult);
                return assignmentResult;
            }
        }
    }

    # Get name of the message broker queue this message processor is consuming messages from.
    #
    # + return - Name of the queue 
    public function getQueueName() returns string {
        return self.processorConfig.storeConfig.queueName;
    }

    # Start Message Processor. This will start polling messages from configured message broker 
    # and forward it to the backend. 
    #
    # + return - `error` in case of starting the polling task
    public function start() returns error? {
        task:Scheduler? task = self.messageForwardingTask;
        if (task is task:Scheduler) {
            check task.start();
        }
    }

    # Stop Messsage Processor. This will stop polling and forwarding messages.
    #
    # + return - `error` in case of stopping Message Processor
    public function stop() returns error? {
        task:Scheduler? task = self.messageForwardingTask;
        if (task is task:Scheduler) {
            check task.start();
            self.active = false;
        }
    }

    # Keep main thread running 
    public function keepRunning() {
        //TODO: fix after (ballerina-lang/issues/16201)
        while (self.active) {
            runtime:sleep(1000);
        }
    }

    # Initialize HTTP client to forward messages.
    #
    # + processorConfig - `ForwardingProcessorConfiguration` config 
    # + return - `http:Client` in case of successful initialization or `error` in case of issue
    function initializeHTTPClient(ForwardingProcessorConfiguration processorConfig) returns http:Client|error {
        http:ClientConfiguration config;
        int[] retryStatusCode = [];
        int[]? processConfigRetryStatusCode = processorConfig?.retryHttpStatusCodes;
        if (processConfigRetryStatusCode is int[]) {
            retryStatusCode = processConfigRetryStatusCode;
        }
        http:RetryConfig retryConfig = {
            intervalInMillis: processorConfig.retryInterval, // Retry interval in milliseconds
            count: processorConfig.maxRedeliveryAttempts,    // Number of retry attempts before giving up
            backOffFactor: 1.0,              // Multiplier of the retry interval
            maxWaitIntervalInMillis: 20000,  // Maximum time of the retry interval in milliseconds
            statusCodes: retryStatusCode     // HTTP response status codes which are considered as failures
        };
        var clientConfig = processorConfig.httpClientConfig;
        if(clientConfig is http:ClientConfiguration) {
            config = clientConfig;
            config.retryConfig = retryConfig;
        } else {
            config = {
                retryConfig: retryConfig
            };
        }
        http:Client backendClientEP = new(processorConfig.HttpEndpointUrl, config);
        return backendClientEP;
    }

    # Clean up JMS objects (connections, sessions and consumers). 
    #
    # + return - `error` in case of stopping and closing JMS objects
    function cleanUpJMSObjects() returns error? {
        check self.messageConsumer.__stop();
        check trap self.jmsConnection->stop();
    }

    # Retry connecting to broker according to given config. This will try forever until connection is successful.
    function retryToConnectBroker(ForwardingProcessorConfiguration processorConfig) {
        MessageStoreConfiguration storeConfig = processorConfig.storeConfig;
        MessageStoreRetryConfig? messageStoreRetryConfig = storeConfig?.retryConfig;

        if (messageStoreRetryConfig is ()) {
            return;
        }

        MessageStoreRetryConfig retryConfig = <MessageStoreRetryConfig> messageStoreRetryConfig;

        int maxRetryCount = retryConfig.count;
        int retryInterval = retryConfig.interval;
        int maxRetryDelay = retryConfig.maxWaitInterval;
        float backOffFactor = retryConfig.backOffFactor;
        int retryCount = 0;
        while (maxRetryCount == -1 || retryCount < maxRetryCount) {
            var consumerInitResult = trap initializeConsumer(storeConfig);
            if (consumerInitResult is error) {
                log:printError("Error while reconnecting to queue = "
                + storeConfig.queueName + " retry count = " + retryCount.toString(), err = consumerInitResult);
                retryCount = retryCount + 1;
                int retryDelay = retryInterval + math:round(retryCount * retryInterval * backOffFactor);
                if (retryDelay > maxRetryDelay) {
                    retryDelay = maxRetryDelay;
                }
                runtime:sleep(retryDelay * 1000);
            } else {
                log:printInfo("Successfuly reconnected to message broker queue = " + processorConfig.storeConfig.queueName);
                var [connection, session, consumer] = consumerInitResult;
                self.jmsConnection = connection;
                self.jmsSession = session;
                self.messageConsumer = consumer;
                break;
            }
        }
        if(retryCount >= maxRetryCount && maxRetryCount != -1) {
            log:printError("Could not connect to message broker. Maximum retry count exceeded. Count = "
                       + maxRetryCount.toString() + ". Retrying stopped.");
        }
    }
};

# Initialize JMS consumer.   
#
# + storeConfig - `MessageStoreConfiguration` configuration 
# + return      - `jms:Connection, jms:Session, jms:MessageConsumer` created JMS connection, session and queue receiver if
#                  created successfully or error in case of an issue when initializing. 
function initializeConsumer(MessageStoreConfiguration storeConfig) returns
                        [jms:Connection, jms:Session, jms:MessageConsumer] | error {

    string initialContextFactory = getInitialContextFactory(storeConfig.messageBroker);
    string acknowledgementMode = "CLIENT_ACKNOWLEDGE";
    string queueName = storeConfig.queueName;

    // Initialize JMS connection with the provider.
    jms:Connection jmsConnection = check jms:createConnection({
        initialContextFactory: initialContextFactory,
        providerUrl: storeConfig.providerUrl});

    // Initialize JMS session on top of the created connection.
    jms:Session jmsSession = check jmsConnection->createSession({
        acknowledgementMode: acknowledgementMode
    });

    // Initialize queue receiver.
    jms:Destination queue = check jmsSession->createQueue(queueName);
    jms:MessageConsumer messageConsumer = check jmsSession->createConsumer(queue);
    [jms:Connection, jms:Session, jms:MessageConsumer] brokerConnection = [jmsConnection, jmsSession, messageConsumer];

    return brokerConnection;
}

# Function pointer to be executed when polling fails.
#
# + processor -  `MessageForwardingProcessor` in which queue consumer should be reset 
# + return    -  A function pointer with logic that closes existing queue consumer of
#                the given processor and re-init another consumer.         
function onMessagePollingFail(MessageForwardingProcessor processor) returns function() {
    return function () {
        log:printInfo("Message polling failed on queue = " + processor.getQueueName());
        var cleanupResult = processor.cleanUpJMSObjects();
        if (cleanupResult is error) {
            log:printError("Error while cleaning up jms connection", err = cleanupResult);
        }
        processor.retryToConnectBroker(processor.processorConfig);
    };
}

# Function pointer to be executed when deactivating message processor.
#
# + processor - Message processor to deactivate
# + return - A function pointer with logic that deactivates message processor
function onDeactivate(MessageForwardingProcessor processor) returns function() {
    return function () {
        log:printInfo("Deactivating message processor on queue = " + processor.getQueueName());
        var processorStopResult = processor.stop();
        if (processorStopResult is error) {
            log:printError("Error when stopping message polling task", err = processorStopResult);
        }
    };
}


# Configuration for Message-forwarding-processor. 
#
# + storeConfig - Config containing store information `MessageStoreConfiguration`  
# + HttpEndpointUrl - Messages will be forwarded to this HTTP url
# + HttpOperation - HTTP Verb to use when forwarding the message
# + httpClientConfig - `ClientConfiguration` HTTP client config to use when forwarding messages to HTTP endpoint
# + pollTimeConfig - Interval messages should be polled from the 
#                    broker (milliseconds) or cron expression for polling task
# + retryInterval - Interval messages should be retried in case of forwading failure (milliseconds)
# + retryHttpStatusCodes - If processor received any response after forwading the message with any of 
#                          these status codes, it will be considered as a failed invocation `int[]` 
# + maxRedeliveryAttempts - Max number of times a message should be retried in case of forwading failure
# + forwardingFailAction - Action to take when a message is failed to forward. `MessageForwardFailAction`
#                          `DROP` - drop message and continue (default)
#                          `DLC_STORE`- store message in configured  `DLCStore`
#                          `DEACTIVATE` - stop message processor                           
# + batchSize - Maximum number of messages to forward when message process task is executed
# + forwardingInterval - Time in milliseconds between two message forwards in a batch
# + DLCStore - In case of forwarding failure, messages will be stored using this backup `Client`. Make sure
# `forwardingFailAction` is `DLC_STORE`
public type ForwardingProcessorConfiguration record {|
    MessageStoreConfiguration storeConfig;
    string HttpEndpointUrl;
    http:HttpOperation HttpOperation = http:HTTP_POST;
    http:ClientConfiguration? httpClientConfig = ();

    // Configured in milliseconds for polling interval; can specify a cron instead
    int|string pollTimeConfig;

    // Forwarding retry configured in milliseconds
    int retryInterval;
    int[] retryHttpStatusCodes?;
    int maxRedeliveryAttempts;  

    // Action on forwarding fail of a message
    MessageForwardFailAction forwardingFailAction = DROP;

    // Batching messages for forwarding
    int batchSize = 1;
    int forwardingInterval = 0;

    // Specify message store client to forward failing messages
    Client DLCStore?;
|};

# Record to be passed to the service attached to message processor task.
#
# + messageConsumer - `jms:MessageConsumer` receiver to use when polling messages
# + queueName - Name of the queue to receive messages from  
# + httpClient - `http:Client` used to forward messages
# + httpEP - Messages will be forwarded to this HTTP url 
# + HttpOperation - HTTP Verb to use when forwarding the message
# + DLCStore - In case of forwarding failure, messages will be stored using this backup `Client`
# + forwardingFailAction - `MessageForwardFailAction` specifying processor behaviour on forwarding failure
# + retryHttpCodes - If processor received any response after forwading the message with any of
#                    these status codes, it will be considered as a failed invocation `int[]` 
# + batchSize - Maximum number of messages to forward upon message process task is executed 
# + forwardingInterval - Time in milliseconds between two message forwards in a batch
# + onMessagePollingFail - Lambda with logic to execute on failing to poll messages from broker `function()`
# + onDeactivate - Lambda with logic to execute when deactivating message processor
# + preProcessRequest - Lambda to be executed upon storing request, before forwarding to the configured endpoint
# + handleResponse - Lambda to be executed when forwarding messages to the configured endpoint upon receiving response
type PollingServiceConfig record {
    jms:MessageConsumer messageConsumer;
    string queueName;
    http:Client httpClient;
    string httpEP;
    http:HttpOperation HttpOperation;
    Client? DLCStore;
    MessageForwardFailAction forwardingFailAction;
    int[] retryHttpCodes;
    int batchSize;
    int forwardingInterval;
    function() onMessagePollingFail;
    function() onDeactivate;
    function(http:Request request)? preProcessRequest;
    function(http:Response resp) handleResponse;
};
