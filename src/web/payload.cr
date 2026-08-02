require "json"
require "../domain/session"

# Turns a SessionView into the exact bytes sent to a client. The view has
# already decided what is visible; this module only chooses the wire shape.
# A hidden ranking is nil in the view, so it serialises to `null` — the card
# names are never written.
module Payload
  def self.session(view : SessionView) : String
    JSON.build do |json|
      json.object do
        json.field "phase", view.phase.to_s.downcase
        json.field "code", view.code
        json.field "participants" do
          json.array do
            view.participants.each { |participant| participant_object(json, participant) }
          end
        end
      end
    end
  end

  private def self.participant_object(json : JSON::Builder, participant : ParticipantView) : Nil
    json.object do
      json.field "name", participant.name
      json.field "ready", participant.ready?
      json.field "you", participant.you?
      json.field "ranking" do
        ranking = participant.ranking
        if ranking.nil?
          json.null
        else
          json.array { ranking.order.each { |card| json.string(card.to_s) } }
        end
      end
    end
  end
end
