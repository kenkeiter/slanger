require 'glamazon'
require 'eventmachine'
require 'forwardable'
require 'fiber'

module Slanger
  class PresenceChannel < Channel
    def_delegators :channel, :push

    def dispatch(message, channel)
      if channel =~ /^slanger:/
        update_subscribers message
      else
        push message.to_json
      end
    end

    def initialize(attrs)
      super
      Slanger::Redis.subscribe 'slanger:connection_notification'
    end

    def subscribe(msg, callback, &blk)
      channel_data = JSON.parse msg['data']['channel_data']
      public_subscription_id = SecureRandom.uuid

      publisher = publish_connection_notification subscription_id: public_subscription_id, online: true,
        channel_data: channel_data, channel: channel_id

      roster_add public_subscription_id, channel_data

      # fuuuuuuuuuccccccck!
      publisher.callback do
        EM.next_tick do
          callback.call
          internal_subscription_table[public_subscription_id] = channel.subscribe &blk
        end
      end

      public_subscription_id
    end

    def ids
      subscriptions.map { |k,v| v['user_id'] }
    end

    def subscribers
      Hash[subscriptions.map { |k,v| [v['user_id'], v['user_info']] }]
    end

    def unsubscribe(public_subscription_id)
      # Unsubcribe from EM::Channel
      channel.unsubscribe(internal_subscription_table.delete(public_subscription_id)) # if internal_subscription_table[public_subscription_id]
      roster_remove public_subscription_id
      # Notify all instances
      publish_connection_notification subscription_id: public_subscription_id, online: false, channel: channel_id
    end

    private

    def get_roster
      Fiber.new do
        f = Fiber.current
        Slanger::Redis.hgetall(channel_id).
          callback { |res| f.resume res }
        Fiber.yield
      end.resume
    end

    def roster_add(key, value)
      Slanger::Redis.hset(channel_id, key, value)
    end

    def roster_remove(key)
      Slanger::Redis.hdel(channel_id, key)
    end

    def publish_connection_notification(payload, retry_count=0)
      Slanger::Redis.publish('slanger:connection_notification', payload.to_json).
        tap { |r| r.errback { publish_connection_notification payload, retry_count.succ unless retry_count == 5 } }
    end

    # This is the state of the presence channel across the system. kept in sync
    # with redis pubsub
    def subscriptions
      @subscriptions = @subscriptions || get_roster || Hash.new
    end

    # This is used map public subscription ids to em channel subscription ids.
    # em channel subscription ids are incremented integers, so they cannot
    # be used as keys in distributed system because they will not be unique
    def internal_subscription_table
      @internal_subscription_table ||= {}
    end

    def update_subscribers(message)
      if message['online']
        # Don't tell the channel subscriptions a new member has been added if the subscriber data
        # is already present in the subscriptions hash, i.e. multiple browser windows open.
        unless subscriptions.has_value? message['channel_data']
          push payload('pusher_internal:member_added', message['channel_data'])
        end
        subscriptions[message['subscription_id']] = message['channel_data']
      else
        # Don't tell the channel subscriptions the member has been removed if the subscriber data
        # still remains in the subscriptions hash, i.e. multiple browser windows open.
        subscriber = subscriptions.delete message['subscription_id']
        unless subscriptions.has_value? subscriber
          push payload('pusher_internal:member_removed', {
            user_id: subscriber['user_id']
          })
        end
      end
    end

    def payload(event_name, payload = {})
      { channel: channel_id, event: event_name, data: payload }.to_json
    end
  end
end
